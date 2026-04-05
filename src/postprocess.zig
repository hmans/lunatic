// postprocess.zig — UE-style bloom: progressive mip-chain downsample/upsample
// with Karis average (firefly suppression) and per-level tinting.
// Based on Jorge Jimenez, "Next Generation Post Processing in Call of Duty:
// Advanced Warfare", SIGGRAPH 2014.

const std = @import("std");
const engine_mod = @import("engine");
const Engine = engine_mod.Engine;
const c = engine_mod.c;

// ============================================================
// Compiled shaders
// ============================================================

const fullscreen_vert_spv = @embedFile("shader_fullscreen_vert_spv");
const fullscreen_vert_msl = @embedFile("shader_fullscreen_vert_msl");
const dof_coc_frag_spv = @embedFile("shader_dof_coc_frag_spv");
const dof_coc_frag_msl = @embedFile("shader_dof_coc_frag_msl");
const dof_prefilter_frag_spv = @embedFile("shader_dof_prefilter_frag_spv");
const dof_prefilter_frag_msl = @embedFile("shader_dof_prefilter_frag_msl");
const dof_bokeh_frag_spv = @embedFile("shader_dof_bokeh_frag_spv");
const dof_bokeh_frag_msl = @embedFile("shader_dof_bokeh_frag_msl");
const dof_composite_frag_spv = @embedFile("shader_dof_composite_frag_spv");
const dof_composite_frag_msl = @embedFile("shader_dof_composite_frag_msl");
const dof_tent_frag_spv = @embedFile("shader_dof_tent_frag_spv");
const dof_tent_frag_msl = @embedFile("shader_dof_tent_frag_msl");
const downsample_frag_spv = @embedFile("shader_downsample_frag_spv");
const downsample_frag_msl = @embedFile("shader_downsample_frag_msl");
const upsample_frag_spv = @embedFile("shader_upsample_frag_spv");
const upsample_frag_msl = @embedFile("shader_upsample_frag_msl");
const composite_frag_spv = @embedFile("shader_composite_frag_spv");
const composite_frag_msl = @embedFile("shader_composite_frag_msl");

// ============================================================
// Uniform structs (must match GLSL layouts)
// ============================================================

const DofParams = extern struct {
    params: [4]f32, // .x = focus_distance, .y = focus_range, .z = max_blur_radius
};

const PrefilterParams = extern struct {
    params: [4]f32, // .xy = texel size of source
};

const BokehParams = extern struct {
    params: [4]f32, // .xy = texel size (half res), .z = max blur radius (half-res pixels)
};

const TentParams = extern struct {
    params: [4]f32, // .xy = texel size
};

const DownsampleParams = extern struct {
    params: [4]f32, // .xy = texel size, .z = is_first_pass
};

const UpsampleParams = extern struct {
    params: [4]f32, // .xy = texel size of lower mip, .z = tint/weight
};

const CompositeParams = extern struct {
    params: [4]f32, // .x = bloom_intensity, .y = exposure
    params2: [4]f32, // .x = vignette_intensity, .y = vignette_smoothness
};

// ============================================================
// Constants
// ============================================================

const hdr_format: c.SDL_GPUTextureFormat = c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT;
pub const max_mip_levels = 6;

// Default per-level tints (UE4-inspired, sum ≈ 1.0)
const default_tints = [max_mip_levels]f32{ 0.5, 0.3, 0.2, 0.15, 0.1, 0.08 };

// ============================================================
// PostProcess state — GPU handles only, no settings
// ============================================================

pub const PostProcessState = struct {
    // HDR scene render targets (full resolution, two for ping-pong)
    hdr_texture: ?*c.SDL_GPUTexture = null,
    hdr_texture_b: ?*c.SDL_GPUTexture = null,

    // Mip chain textures for bloom (downsample targets / upsample sources)
    mip_textures: [max_mip_levels]?*c.SDL_GPUTexture = .{null} ** max_mip_levels,
    mip_widths: [max_mip_levels]u32 = .{0} ** max_mip_levels,
    mip_heights: [max_mip_levels]u32 = .{0} ** max_mip_levels,
    mip_count: u32 = 0,
    cached_w: u32 = 0,
    cached_h: u32 = 0,

    // Pipelines
    downsample_pipeline: ?*c.SDL_GPUGraphicsPipeline = null,
    upsample_pipeline: ?*c.SDL_GPUGraphicsPipeline = null,
    composite_pipeline: ?*c.SDL_GPUGraphicsPipeline = null,

    // Sampler for post-process texture reads (linear, clamp-to-edge)
    sampler: ?*c.SDL_GPUSampler = null,

    // Bloom shape — per-level tint weights (mutable, tweak via debug UI)
    tints: [max_mip_levels]f32 = default_tints,
    // Upsample filter radius multiplier (1.0 = standard, >1 = wider bloom)
    radius: f32 = 1.0,

    // DoF textures (created alongside bloom textures)
    dof_coc: ?*c.SDL_GPUTexture = null, // R16F, full res — signed CoC
    dof_half: ?*c.SDL_GPUTexture = null, // RGBA16F, half res — prefiltered
    dof_bokeh: ?*c.SDL_GPUTexture = null, // RGBA16F, half res — gather result

    // DoF pipelines
    dof_coc_pipeline: ?*c.SDL_GPUGraphicsPipeline = null,
    dof_prefilter_pipeline: ?*c.SDL_GPUGraphicsPipeline = null,
    dof_bokeh_pipeline: ?*c.SDL_GPUGraphicsPipeline = null,
    dof_composite_pipeline: ?*c.SDL_GPUGraphicsPipeline = null,
    dof_tent_pipeline: ?*c.SDL_GPUGraphicsPipeline = null,
};

/// Per-camera post-processing settings, read from Camera component fields.
pub const CameraPostSettings = struct {
    exposure: f32,
    bloom_intensity: f32,
    dof_focus_dist: f32,
    dof_focus_range: f32,
    dof_blur_radius: f32,
    vignette_intensity: f32,
    vignette_smoothness: f32,
};

// ============================================================
// Shader helper
// ============================================================

fn createShader(device: *c.SDL_GPUDevice, spv: []const u8, msl: []const u8, stage: c.SDL_GPUShaderStage, num_uniform_buffers: u32, num_samplers: u32) ?*c.SDL_GPUShader {
    const formats = c.SDL_GetGPUShaderFormats(device);

    var code: [*]const u8 = undefined;
    var code_size: usize = undefined;
    var format: c.SDL_GPUShaderFormat = undefined;
    var entrypoint: [*:0]const u8 = undefined;

    if (formats & c.SDL_GPU_SHADERFORMAT_SPIRV != 0) {
        code = spv.ptr;
        code_size = spv.len;
        format = c.SDL_GPU_SHADERFORMAT_SPIRV;
        entrypoint = "main";
    } else if (formats & c.SDL_GPU_SHADERFORMAT_MSL != 0) {
        code = msl.ptr;
        code_size = msl.len;
        format = c.SDL_GPU_SHADERFORMAT_MSL;
        entrypoint = "main0";
    } else {
        return null;
    }

    return c.SDL_CreateGPUShader(device, &c.SDL_GPUShaderCreateInfo{
        .code_size = code_size,
        .code = code,
        .entrypoint = entrypoint,
        .format = format,
        .stage = stage,
        .num_samplers = num_samplers,
        .num_storage_textures = 0,
        .num_storage_buffers = 0,
        .num_uniform_buffers = num_uniform_buffers,
        .props = 0,
    });
}

// ============================================================
// Texture creation
// ============================================================

fn createRenderTexture(device: *c.SDL_GPUDevice, format: c.SDL_GPUTextureFormat, w: u32, h: u32) ?*c.SDL_GPUTexture {
    return c.SDL_CreateGPUTexture(device, &c.SDL_GPUTextureCreateInfo{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = format,
        .usage = c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
        .width = w,
        .height = h,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
        .props = 0,
    });
}

// ============================================================
// Pipeline creation
// ============================================================

fn createPostProcessPipeline(
    device: *c.SDL_GPUDevice,
    frag_spv: []const u8,
    frag_msl: []const u8,
    target_format: c.SDL_GPUTextureFormat,
    num_frag_uniforms: u32,
    num_frag_samplers: u32,
) ?*c.SDL_GPUGraphicsPipeline {
    const vert_shader = createShader(device, fullscreen_vert_spv, fullscreen_vert_msl, c.SDL_GPU_SHADERSTAGE_VERTEX, 0, 0) orelse return null;
    defer c.SDL_ReleaseGPUShader(device, vert_shader);

    const frag_shader = createShader(device, frag_spv, frag_msl, c.SDL_GPU_SHADERSTAGE_FRAGMENT, num_frag_uniforms, num_frag_samplers) orelse return null;
    defer c.SDL_ReleaseGPUShader(device, frag_shader);

    const color_target_desc = [_]c.SDL_GPUColorTargetDescription{
        .{ .format = target_format, .blend_state = std.mem.zeroes(c.SDL_GPUColorTargetBlendState) },
    };

    return c.SDL_CreateGPUGraphicsPipeline(device, &c.SDL_GPUGraphicsPipelineCreateInfo{
        .vertex_shader = vert_shader,
        .fragment_shader = frag_shader,
        .vertex_input_state = .{
            .vertex_buffer_descriptions = null,
            .num_vertex_buffers = 0,
            .vertex_attributes = null,
            .num_vertex_attributes = 0,
        },
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .rasterizer_state = .{
            .fill_mode = c.SDL_GPU_FILLMODE_FILL,
            .cull_mode = c.SDL_GPU_CULLMODE_NONE,
            .front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .enable_depth_bias = false,
            .enable_depth_clip = false,
            .padding1 = 0,
            .padding2 = 0,
        },
        .multisample_state = .{
            .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
            .sample_mask = 0,
            .enable_mask = false,
            .enable_alpha_to_coverage = false,
            .padding2 = 0,
            .padding3 = 0,
        },
        .depth_stencil_state = std.mem.zeroes(c.SDL_GPUDepthStencilState),
        .target_info = .{
            .color_target_descriptions = &color_target_desc,
            .num_color_targets = 1,
            .depth_stencil_format = c.SDL_GPU_TEXTUREFORMAT_INVALID,
            .has_depth_stencil_target = false,
            .padding1 = 0,
            .padding2 = 0,
            .padding3 = 0,
        },
        .props = 0,
    });
}

/// Like createPostProcessPipeline but with additive blending (src + dst).
fn createAdditivePipeline(
    device: *c.SDL_GPUDevice,
    frag_spv: []const u8,
    frag_msl: []const u8,
    target_format: c.SDL_GPUTextureFormat,
    num_frag_uniforms: u32,
    num_frag_samplers: u32,
) ?*c.SDL_GPUGraphicsPipeline {
    const vert_shader = createShader(device, fullscreen_vert_spv, fullscreen_vert_msl, c.SDL_GPU_SHADERSTAGE_VERTEX, 0, 0) orelse return null;
    defer c.SDL_ReleaseGPUShader(device, vert_shader);

    const frag_shader = createShader(device, frag_spv, frag_msl, c.SDL_GPU_SHADERSTAGE_FRAGMENT, num_frag_uniforms, num_frag_samplers) orelse return null;
    defer c.SDL_ReleaseGPUShader(device, frag_shader);

    const blend_state = c.SDL_GPUColorTargetBlendState{
        .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
        .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
        .color_blend_op = c.SDL_GPU_BLENDOP_ADD,
        .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
        .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
        .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD,
        .color_write_mask = c.SDL_GPU_COLORCOMPONENT_R | c.SDL_GPU_COLORCOMPONENT_G | c.SDL_GPU_COLORCOMPONENT_B | c.SDL_GPU_COLORCOMPONENT_A,
        .enable_blend = true,
        .enable_color_write_mask = false,
        .padding1 = 0,
        .padding2 = 0,
    };

    const color_target_desc = [_]c.SDL_GPUColorTargetDescription{
        .{ .format = target_format, .blend_state = blend_state },
    };

    return c.SDL_CreateGPUGraphicsPipeline(device, &c.SDL_GPUGraphicsPipelineCreateInfo{
        .vertex_shader = vert_shader,
        .fragment_shader = frag_shader,
        .vertex_input_state = .{
            .vertex_buffer_descriptions = null,
            .num_vertex_buffers = 0,
            .vertex_attributes = null,
            .num_vertex_attributes = 0,
        },
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .rasterizer_state = .{
            .fill_mode = c.SDL_GPU_FILLMODE_FILL,
            .cull_mode = c.SDL_GPU_CULLMODE_NONE,
            .front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .enable_depth_bias = false,
            .enable_depth_clip = false,
            .padding1 = 0,
            .padding2 = 0,
        },
        .multisample_state = .{
            .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
            .sample_mask = 0,
            .enable_mask = false,
            .enable_alpha_to_coverage = false,
            .padding2 = 0,
            .padding3 = 0,
        },
        .depth_stencil_state = std.mem.zeroes(c.SDL_GPUDepthStencilState),
        .target_info = .{
            .color_target_descriptions = &color_target_desc,
            .num_color_targets = 1,
            .depth_stencil_format = c.SDL_GPU_TEXTUREFORMAT_INVALID,
            .has_depth_stencil_target = false,
            .padding1 = 0,
            .padding2 = 0,
            .padding3 = 0,
        },
        .props = 0,
    });
}

// ============================================================
// Initialization
// ============================================================

pub fn initPostProcess(self: *Engine) !void {
    const device = self.gpu_device.?;

    // Clamp-to-edge sampler for post-process reads
    self.postprocess.sampler = c.SDL_CreateGPUSampler(device, &c.SDL_GPUSamplerCreateInfo{
        .min_filter = c.SDL_GPU_FILTER_LINEAR,
        .mag_filter = c.SDL_GPU_FILTER_LINEAR,
        .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST,
        .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .mip_lod_bias = 0,
        .max_anisotropy = 1,
        .compare_op = 0,
        .min_lod = 0,
        .max_lod = 0,
        .enable_anisotropy = false,
        .enable_compare = false,
        .padding1 = 0,
        .padding2 = 0,
        .props = 0,
    }) orelse return error.SamplerFailed;

    // Pipelines
    self.postprocess.downsample_pipeline = createPostProcessPipeline(
        device,
        downsample_frag_spv,
        downsample_frag_msl,
        hdr_format,
        1, // uniforms
        1, // samplers
    ) orelse return error.PipelineFailed;

    self.postprocess.upsample_pipeline = createAdditivePipeline(
        device,
        upsample_frag_spv,
        upsample_frag_msl,
        hdr_format,
        1, // uniforms
        1, // samplers (lower_mip only)
    ) orelse return error.PipelineFailed;

    self.postprocess.composite_pipeline = createPostProcessPipeline(
        device,
        composite_frag_spv,
        composite_frag_msl,
        self.swapchain_format,
        1,
        2,
    ) orelse return error.PipelineFailed;

    // DoF pipelines
    self.postprocess.dof_coc_pipeline = createPostProcessPipeline(
        device, dof_coc_frag_spv, dof_coc_frag_msl,
        c.SDL_GPU_TEXTUREFORMAT_R16_FLOAT, 1, 1,
    ) orelse return error.PipelineFailed;

    self.postprocess.dof_prefilter_pipeline = createPostProcessPipeline(
        device, dof_prefilter_frag_spv, dof_prefilter_frag_msl,
        hdr_format, 1, 2,
    ) orelse return error.PipelineFailed;

    self.postprocess.dof_bokeh_pipeline = createPostProcessPipeline(
        device, dof_bokeh_frag_spv, dof_bokeh_frag_msl,
        hdr_format, 1, 1,
    ) orelse return error.PipelineFailed;

    self.postprocess.dof_composite_pipeline = createPostProcessPipeline(
        device, dof_composite_frag_spv, dof_composite_frag_msl,
        hdr_format, 0, 3,
    ) orelse return error.PipelineFailed;

    self.postprocess.dof_tent_pipeline = createPostProcessPipeline(
        device, dof_tent_frag_spv, dof_tent_frag_msl,
        hdr_format, 1, 1,
    ) orelse return error.PipelineFailed;

    // Textures at initial resolution
    try ensureTextures(self, self.rt_w, self.rt_h);
}

/// (Re)create HDR and mip chain textures if resolution changed.
pub fn ensureTextures(self: *Engine, w: u32, h: u32) !void {
    const device = self.gpu_device.?;
    const pp = &self.postprocess;

    if (pp.cached_w == w and pp.cached_h == h and pp.hdr_texture != null) return;

    // Release old textures
    if (pp.hdr_texture) |t| c.SDL_ReleaseGPUTexture(device, t);
    if (pp.hdr_texture_b) |t| c.SDL_ReleaseGPUTexture(device, t);
    if (pp.dof_coc) |t| c.SDL_ReleaseGPUTexture(device, t);
    if (pp.dof_half) |t| c.SDL_ReleaseGPUTexture(device, t);
    if (pp.dof_bokeh) |t| c.SDL_ReleaseGPUTexture(device, t);
    for (&pp.mip_textures) |*mt| {
        if (mt.*) |t| c.SDL_ReleaseGPUTexture(device, t);
        mt.* = null;
    }

    pp.hdr_texture = createRenderTexture(device, hdr_format, w, h) orelse return error.TextureFailed;
    pp.hdr_texture_b = createRenderTexture(device, hdr_format, w, h) orelse return error.TextureFailed;

    // DoF textures
    pp.dof_coc = createRenderTexture(device, c.SDL_GPU_TEXTUREFORMAT_R16_FLOAT, w, h) orelse return error.TextureFailed;
    const half_w = @max(w / 2, 1);
    const half_h = @max(h / 2, 1);
    pp.dof_half = createRenderTexture(device, hdr_format, half_w, half_h) orelse return error.TextureFailed;
    pp.dof_bokeh = createRenderTexture(device, hdr_format, half_w, half_h) orelse return error.TextureFailed;

    // Build mip chain: each level is half the previous, starting from full res
    var mw = w;
    var mh = h;
    var count: u32 = 0;
    while (count < max_mip_levels and mw > 1 and mh > 1) {
        mw = @max(mw / 2, 1);
        mh = @max(mh / 2, 1);
        pp.mip_textures[count] = createRenderTexture(device, hdr_format, mw, mh) orelse return error.TextureFailed;
        pp.mip_widths[count] = mw;
        pp.mip_heights[count] = mh;
        count += 1;
    }
    pp.mip_count = count;
    pp.cached_w = w;
    pp.cached_h = h;
}

// ============================================================
// Cleanup
// ============================================================

pub fn deinitPostProcess(self: *Engine) void {
    const device = self.gpu_device orelse return;
    const pp = &self.postprocess;
    if (pp.hdr_texture) |t| c.SDL_ReleaseGPUTexture(device, t);
    if (pp.hdr_texture_b) |t| c.SDL_ReleaseGPUTexture(device, t);
    for (pp.mip_textures) |mt| {
        if (mt) |t| c.SDL_ReleaseGPUTexture(device, t);
    }
    if (pp.dof_coc) |t| c.SDL_ReleaseGPUTexture(device, t);
    if (pp.dof_half) |t| c.SDL_ReleaseGPUTexture(device, t);
    if (pp.dof_bokeh) |t| c.SDL_ReleaseGPUTexture(device, t);
    if (pp.downsample_pipeline) |p| c.SDL_ReleaseGPUGraphicsPipeline(device, p);
    if (pp.upsample_pipeline) |p| c.SDL_ReleaseGPUGraphicsPipeline(device, p);
    if (pp.composite_pipeline) |p| c.SDL_ReleaseGPUGraphicsPipeline(device, p);
    if (pp.dof_coc_pipeline) |p| c.SDL_ReleaseGPUGraphicsPipeline(device, p);
    if (pp.dof_prefilter_pipeline) |p| c.SDL_ReleaseGPUGraphicsPipeline(device, p);
    if (pp.dof_bokeh_pipeline) |p| c.SDL_ReleaseGPUGraphicsPipeline(device, p);
    if (pp.dof_composite_pipeline) |p| c.SDL_ReleaseGPUGraphicsPipeline(device, p);
    if (pp.dof_tent_pipeline) |p| c.SDL_ReleaseGPUGraphicsPipeline(device, p);
    if (pp.sampler) |s| c.SDL_ReleaseGPUSampler(device, s);
}

// ============================================================
// Fullscreen pass helpers
// ============================================================

fn beginFullscreenPass(cmd: *c.SDL_GPUCommandBuffer, target: *c.SDL_GPUTexture) ?*c.SDL_GPURenderPass {
    const color_target = c.SDL_GPUColorTargetInfo{
        .texture = target,
        .mip_level = 0,
        .layer_or_depth_plane = 0,
        .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .load_op = c.SDL_GPU_LOADOP_CLEAR,
        .store_op = c.SDL_GPU_STOREOP_STORE,
        .resolve_texture = null,
        .resolve_mip_level = 0,
        .resolve_layer = 0,
        .cycle = false,
        .cycle_resolve_texture = false,
        .padding1 = 0,
        .padding2 = 0,
    };
    return c.SDL_BeginGPURenderPass(cmd, &color_target, 1, null);
}

fn setFullscreenViewport(pass: *c.SDL_GPURenderPass, w: u32, h: u32) void {
    const wf: f32 = @floatFromInt(w);
    const hf: f32 = @floatFromInt(h);
    c.SDL_SetGPUViewport(pass, &c.SDL_GPUViewport{ .x = 0, .y = 0, .w = wf, .h = hf, .min_depth = 0, .max_depth = 1 });
    c.SDL_SetGPUScissor(pass, &c.SDL_Rect{ .x = 0, .y = 0, .w = @intCast(w), .h = @intCast(h) });
}

fn drawFullscreenTriangle(pass: *c.SDL_GPURenderPass) void {
    c.SDL_DrawGPUPrimitives(pass, 3, 1, 0, 0);
}

// ============================================================
// Post-processing execution
// ============================================================

/// Run post-processing for a single camera.
/// DoF (if enabled) → bloom → composite with tone mapping.
pub fn executePostProcess(self: *Engine, cmd: *c.SDL_GPUCommandBuffer, swapchain_tex: *c.SDL_GPUTexture, sw_w: u32, sw_h: u32, settings: CameraPostSettings) void {
    const pp = &self.postprocess;
    const sampler = pp.sampler orelse return;
    const mip_count = pp.mip_count;
    const half_w = @max(sw_w / 2, 1);
    const half_h = @max(sw_h / 2, 1);
    const sw_wf: f32 = @floatFromInt(sw_w);
    const sw_hf: f32 = @floatFromInt(sw_h);
    const half_wf: f32 = @floatFromInt(half_w);
    const half_hf: f32 = @floatFromInt(half_h);

    // === Depth of Field (before bloom, operates on HDR texture) ===
    if (settings.dof_focus_dist > 0) {
        // Pass 1: CoC from depth (stored in HDR alpha)
        {
            const pass = beginFullscreenPass(cmd, pp.dof_coc.?) orelse return;
            c.SDL_BindGPUGraphicsPipeline(pass, pp.dof_coc_pipeline.?);
            setFullscreenViewport(pass, sw_w, sw_h);
            const binding = [1]c.SDL_GPUTextureSamplerBinding{
                .{ .texture = pp.hdr_texture.?, .sampler = sampler },
            };
            c.SDL_BindGPUFragmentSamplers(pass, 0, &binding, 1);
            const params = DofParams{ .params = .{ settings.dof_focus_dist, settings.dof_focus_range, settings.dof_blur_radius, 0 } };
            c.SDL_PushGPUFragmentUniformData(cmd, 0, &params, @sizeOf(DofParams));
            drawFullscreenTriangle(pass);
            c.SDL_EndGPURenderPass(pass);
        }

        // Pass 2: Prefilter downsample to half res
        {
            const pass = beginFullscreenPass(cmd, pp.dof_half.?) orelse return;
            c.SDL_BindGPUGraphicsPipeline(pass, pp.dof_prefilter_pipeline.?);
            setFullscreenViewport(pass, half_w, half_h);
            const bindings = [2]c.SDL_GPUTextureSamplerBinding{
                .{ .texture = pp.hdr_texture.?, .sampler = sampler },
                .{ .texture = pp.dof_coc.?, .sampler = sampler },
            };
            c.SDL_BindGPUFragmentSamplers(pass, 0, &bindings, 2);
            const params = PrefilterParams{ .params = .{ 1.0 / sw_wf, 1.0 / sw_hf, 0, 0 } };
            c.SDL_PushGPUFragmentUniformData(cmd, 0, &params, @sizeOf(PrefilterParams));
            drawFullscreenTriangle(pass);
            c.SDL_EndGPURenderPass(pass);
        }

        // Pass 3: Bokeh gather at half res
        {
            const pass = beginFullscreenPass(cmd, pp.dof_bokeh.?) orelse return;
            c.SDL_BindGPUGraphicsPipeline(pass, pp.dof_bokeh_pipeline.?);
            setFullscreenViewport(pass, half_w, half_h);
            const binding = [1]c.SDL_GPUTextureSamplerBinding{
                .{ .texture = pp.dof_half.?, .sampler = sampler },
            };
            c.SDL_BindGPUFragmentSamplers(pass, 0, &binding, 1);
            const params = BokehParams{ .params = .{ 1.0 / half_wf, 1.0 / half_hf, settings.dof_blur_radius * 0.5, 0 } };
            c.SDL_PushGPUFragmentUniformData(cmd, 0, &params, @sizeOf(BokehParams));
            drawFullscreenTriangle(pass);
            c.SDL_EndGPURenderPass(pass);
        }

        // Pass 4: Tent post-filter — smooth bokeh noise (dof_bokeh → dof_half)
        {
            const pass = beginFullscreenPass(cmd, pp.dof_half.?) orelse return;
            c.SDL_BindGPUGraphicsPipeline(pass, pp.dof_tent_pipeline.?);
            setFullscreenViewport(pass, half_w, half_h);
            const binding = [1]c.SDL_GPUTextureSamplerBinding{
                .{ .texture = pp.dof_bokeh.?, .sampler = sampler },
            };
            c.SDL_BindGPUFragmentSamplers(pass, 0, &binding, 1);
            const tent_params = TentParams{ .params = .{ 1.0 / half_wf, 1.0 / half_hf, 0, 0 } };
            c.SDL_PushGPUFragmentUniformData(cmd, 0, &tent_params, @sizeOf(TentParams));
            drawFullscreenTriangle(pass);
            c.SDL_EndGPURenderPass(pass);
        }

        // Pass 5: Composite DoF → hdr_texture_b (can't read+write same texture)
        {
            const pass = beginFullscreenPass(cmd, pp.hdr_texture_b.?) orelse return;
            c.SDL_BindGPUGraphicsPipeline(pass, pp.dof_composite_pipeline.?);
            setFullscreenViewport(pass, sw_w, sw_h);
            const bindings = [3]c.SDL_GPUTextureSamplerBinding{
                .{ .texture = pp.hdr_texture.?, .sampler = sampler },
                .{ .texture = pp.dof_half.?, .sampler = sampler }, // post-filtered
                .{ .texture = pp.dof_coc.?, .sampler = sampler },
            };
            c.SDL_BindGPUFragmentSamplers(pass, 0, &bindings, 3);
            drawFullscreenTriangle(pass);
            c.SDL_EndGPURenderPass(pass);
        }

        // Swap: hdr_texture_b is now the active HDR buffer
        const tmp = pp.hdr_texture;
        pp.hdr_texture = pp.hdr_texture_b;
        pp.hdr_texture_b = tmp;
    }

    // === Bloom (reads from hdr_texture, which may have been swapped by DoF) ===
    if (settings.bloom_intensity > 0 and mip_count > 0) {
        // === Downsample chain: HDR → mip0 → mip1 → ... → mipN ===
        var i: u32 = 0;
        while (i < mip_count) : (i += 1) {
            const target = pp.mip_textures[i].?;
            const tw = pp.mip_widths[i];
            const th = pp.mip_heights[i];

            // Source is either HDR texture (for first pass) or previous mip
            const source = if (i == 0) pp.hdr_texture.? else pp.mip_textures[i - 1].?;
            const src_w: f32 = if (i == 0) @floatFromInt(sw_w) else @floatFromInt(pp.mip_widths[i - 1]);
            const src_h: f32 = if (i == 0) @floatFromInt(sw_h) else @floatFromInt(pp.mip_heights[i - 1]);

            const pass = beginFullscreenPass(cmd, target) orelse return;
            c.SDL_BindGPUGraphicsPipeline(pass, pp.downsample_pipeline.?);
            setFullscreenViewport(pass, tw, th);

            const binding = [1]c.SDL_GPUTextureSamplerBinding{
                .{ .texture = source, .sampler = sampler },
            };
            c.SDL_BindGPUFragmentSamplers(pass, 0, &binding, 1);

            const is_first: f32 = if (i == 0) 1.0 else 0.0;
            const params = DownsampleParams{ .params = .{ 1.0 / src_w, 1.0 / src_h, is_first, 0 } };
            c.SDL_PushGPUFragmentUniformData(cmd, 0, &params, @sizeOf(DownsampleParams));

            drawFullscreenTriangle(pass);
            c.SDL_EndGPURenderPass(pass);
        }

        // === Upsample chain: mipN → mipN-1 → ... → mip0 ===
        // Work bottom-up. At each level, the mip texture gets overwritten with
        // its original downsample + the tinted upsampled result from the level below.
        if (mip_count >= 2) {
            var j: u32 = mip_count - 1;
            while (j > 0) {
                j -= 1;
                const target_w = pp.mip_widths[j];
                const target_h = pp.mip_heights[j];

                const lower = pp.mip_textures[j + 1].?;
                const lower_w: f32 = @floatFromInt(pp.mip_widths[j + 1]);
                const lower_h: f32 = @floatFromInt(pp.mip_heights[j + 1]);

                // LOADOP_LOAD preserves the downsample content; additive blend
                // pipeline adds the tent-filtered lower mip on top.
                const color_target = c.SDL_GPUColorTargetInfo{
                    .texture = pp.mip_textures[j].?,
                    .mip_level = 0,
                    .layer_or_depth_plane = 0,
                    .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                    .load_op = c.SDL_GPU_LOADOP_LOAD, // preserve downsample content
                    .store_op = c.SDL_GPU_STOREOP_STORE,
                    .resolve_texture = null,
                    .resolve_mip_level = 0,
                    .resolve_layer = 0,
                    .cycle = false,
                    .cycle_resolve_texture = false,
                    .padding1 = 0,
                    .padding2 = 0,
                };
                const pass = c.SDL_BeginGPURenderPass(cmd, &color_target, 1, null) orelse return;
                c.SDL_BindGPUGraphicsPipeline(pass, pp.upsample_pipeline.?);
                setFullscreenViewport(pass, target_w, target_h);

                // Only bind the lower mip — current mip is preserved via LOADOP_LOAD
                const binding = [1]c.SDL_GPUTextureSamplerBinding{
                    .{ .texture = lower, .sampler = sampler },
                };
                c.SDL_BindGPUFragmentSamplers(pass, 0, &binding, 1);

                const tint = if (j + 1 < max_mip_levels) pp.tints[j + 1] else 0.1;
                const params = UpsampleParams{ .params = .{ pp.radius / lower_w, pp.radius / lower_h, tint, 0 } };
                c.SDL_PushGPUFragmentUniformData(cmd, 0, &params, @sizeOf(UpsampleParams));

                drawFullscreenTriangle(pass);
                c.SDL_EndGPURenderPass(pass);
            }
        }
    }

    // === Composite: HDR scene + bloom (mip0) → swapchain ===
    {
        const pass = beginFullscreenPass(cmd, swapchain_tex) orelse return;
        c.SDL_BindGPUGraphicsPipeline(pass, pp.composite_pipeline.?);
        setFullscreenViewport(pass, sw_w, sw_h);

        // bloom source is mip0 (accumulated upsample result), or HDR if no bloom
        const bloom_tex = if (settings.bloom_intensity > 0 and pp.mip_count > 0)
            pp.mip_textures[0].?
        else
            pp.hdr_texture.?;

        const bindings = [2]c.SDL_GPUTextureSamplerBinding{
            .{ .texture = pp.hdr_texture.?, .sampler = sampler },
            .{ .texture = bloom_tex, .sampler = sampler },
        };
        c.SDL_BindGPUFragmentSamplers(pass, 0, &bindings, 2);

        const params = CompositeParams{
            .params = .{ settings.bloom_intensity, settings.exposure, 0, 0 },
            .params2 = .{ settings.vignette_intensity, settings.vignette_smoothness, 0, 0 },
        };
        c.SDL_PushGPUFragmentUniformData(cmd, 0, &params, @sizeOf(CompositeParams));

        drawFullscreenTriangle(pass);
        c.SDL_EndGPURenderPass(pass);
    }
}
