// postprocess.zig — Bloom post-processing: HDR render target, threshold extraction,
// separable Gaussian blur, and final composite with tone mapping.

const std = @import("std");
const engine_mod = @import("engine");
const Engine = engine_mod.Engine;
const c = engine_mod.c;

// ============================================================
// Compiled shaders
// ============================================================

const fullscreen_vert_spv = @embedFile("shader_fullscreen_vert_spv");
const fullscreen_vert_msl = @embedFile("shader_fullscreen_vert_msl");
const threshold_frag_spv = @embedFile("shader_threshold_frag_spv");
const threshold_frag_msl = @embedFile("shader_threshold_frag_msl");
const blur_frag_spv = @embedFile("shader_blur_frag_spv");
const blur_frag_msl = @embedFile("shader_blur_frag_msl");
const composite_frag_spv = @embedFile("shader_composite_frag_spv");
const composite_frag_msl = @embedFile("shader_composite_frag_msl");

// ============================================================
// Uniform structs (must match GLSL layouts)
// ============================================================

const BloomParams = extern struct {
    params: [4]f32, // .x = threshold, .y = soft_knee, .z = intensity
};

const BlurParams = extern struct {
    direction: [4]f32, // .xy = blur direction in texel space
};

const CompositeParams = extern struct {
    params: [4]f32, // .x = bloom_intensity, .y = exposure
};

// ============================================================
// HDR format
// ============================================================

const hdr_format: c.SDL_GPUTextureFormat = c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT;

// ============================================================
// PostProcess state — stored as fields on Engine
// ============================================================

pub const PostProcessState = struct {
    // HDR scene render target (full resolution)
    hdr_texture: ?*c.SDL_GPUTexture = null,
    // Bloom ping-pong textures (half resolution)
    bloom_a: ?*c.SDL_GPUTexture = null,
    bloom_b: ?*c.SDL_GPUTexture = null,
    bloom_w: u32 = 0,
    bloom_h: u32 = 0,

    // Pipelines
    threshold_pipeline: ?*c.SDL_GPUGraphicsPipeline = null,
    blur_pipeline: ?*c.SDL_GPUGraphicsPipeline = null,
    composite_pipeline: ?*c.SDL_GPUGraphicsPipeline = null,

    // Sampler for post-process texture reads (linear, clamp-to-edge)
    sampler: ?*c.SDL_GPUSampler = null,
};

/// Per-camera bloom settings, read from Camera component fields.
pub const BloomSettings = struct {
    exposure: f32,
    threshold: f32,
    intensity: f32,
    soft_knee: f32,
    blur_passes: u32,
};

// ============================================================
// Shader helper (same pattern as renderer.zig)
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

    // Pipelines: threshold → HDR, blur → HDR, composite → swapchain
    self.postprocess.threshold_pipeline = createPostProcessPipeline(
        device,
        threshold_frag_spv,
        threshold_frag_msl,
        hdr_format,
        1,
        1,
    ) orelse return error.PipelineFailed;

    self.postprocess.blur_pipeline = createPostProcessPipeline(
        device,
        blur_frag_spv,
        blur_frag_msl,
        hdr_format,
        1,
        1,
    ) orelse return error.PipelineFailed;

    self.postprocess.composite_pipeline = createPostProcessPipeline(
        device,
        composite_frag_spv,
        composite_frag_msl,
        self.swapchain_format,
        1,
        2,
    ) orelse return error.PipelineFailed;

    // HDR + bloom textures at initial resolution
    try ensureTextures(self, self.rt_w, self.rt_h);
}

/// (Re)create HDR and bloom textures if resolution changed.
pub fn ensureTextures(self: *Engine, w: u32, h: u32) !void {
    const device = self.gpu_device.?;
    const bloom_w = @max(w / 2, 1);
    const bloom_h = @max(h / 2, 1);

    // Only recreate if size actually changed
    if (self.postprocess.bloom_w == bloom_w and self.postprocess.bloom_h == bloom_h and self.postprocess.hdr_texture != null) return;

    // Release old textures
    if (self.postprocess.hdr_texture) |t| c.SDL_ReleaseGPUTexture(device, t);
    if (self.postprocess.bloom_a) |t| c.SDL_ReleaseGPUTexture(device, t);
    if (self.postprocess.bloom_b) |t| c.SDL_ReleaseGPUTexture(device, t);

    self.postprocess.hdr_texture = createRenderTexture(device, hdr_format, w, h) orelse return error.TextureFailed;
    self.postprocess.bloom_a = createRenderTexture(device, hdr_format, bloom_w, bloom_h) orelse return error.TextureFailed;
    self.postprocess.bloom_b = createRenderTexture(device, hdr_format, bloom_w, bloom_h) orelse return error.TextureFailed;
    self.postprocess.bloom_w = bloom_w;
    self.postprocess.bloom_h = bloom_h;
}

// ============================================================
// Cleanup
// ============================================================

pub fn deinitPostProcess(self: *Engine) void {
    const device = self.gpu_device orelse return;
    const pp = &self.postprocess;
    if (pp.hdr_texture) |t| c.SDL_ReleaseGPUTexture(device, t);
    if (pp.bloom_a) |t| c.SDL_ReleaseGPUTexture(device, t);
    if (pp.bloom_b) |t| c.SDL_ReleaseGPUTexture(device, t);
    if (pp.threshold_pipeline) |p| c.SDL_ReleaseGPUGraphicsPipeline(device, p);
    if (pp.blur_pipeline) |p| c.SDL_ReleaseGPUGraphicsPipeline(device, p);
    if (pp.composite_pipeline) |p| c.SDL_ReleaseGPUGraphicsPipeline(device, p);
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
// Bloom execution — called after the scene has been rendered to hdr_texture
// ============================================================

/// Run post-processing for a single camera. Always runs composite (tone mapping + gamma).
/// When bloom intensity > 0, also runs threshold extraction + blur.
pub fn executePostProcess(self: *Engine, cmd: *c.SDL_GPUCommandBuffer, swapchain_tex: *c.SDL_GPUTexture, sw_w: u32, sw_h: u32, settings: BloomSettings) void {
    const pp = &self.postprocess;
    const sampler = pp.sampler orelse return;
    const bloom_w = pp.bloom_w;
    const bloom_h = pp.bloom_h;

    if (settings.intensity > 0) {
        // Pass 1: Threshold extraction — HDR scene → bloom_a (half res)
        {
            const pass = beginFullscreenPass(cmd, pp.bloom_a.?) orelse return;
            c.SDL_BindGPUGraphicsPipeline(pass, pp.threshold_pipeline.?);
            setFullscreenViewport(pass, bloom_w, bloom_h);

            const binding = [1]c.SDL_GPUTextureSamplerBinding{
                .{ .texture = pp.hdr_texture.?, .sampler = sampler },
            };
            c.SDL_BindGPUFragmentSamplers(pass, 0, &binding, 1);

            const params = BloomParams{ .params = .{ settings.threshold, settings.soft_knee, settings.intensity, 0 } };
            c.SDL_PushGPUFragmentUniformData(cmd, 0, &params, @sizeOf(BloomParams));

            drawFullscreenTriangle(pass);
            c.SDL_EndGPURenderPass(pass);
        }

        // Pass 2+3: Separable Gaussian blur (repeat blur_passes times)
        const texel_w: f32 = 1.0 / @as(f32, @floatFromInt(bloom_w));
        const texel_h: f32 = 1.0 / @as(f32, @floatFromInt(bloom_h));

        var i: u32 = 0;
        while (i < settings.blur_passes) : (i += 1) {
            // Horizontal: bloom_a → bloom_b
            {
                const pass = beginFullscreenPass(cmd, pp.bloom_b.?) orelse return;
                c.SDL_BindGPUGraphicsPipeline(pass, pp.blur_pipeline.?);
                setFullscreenViewport(pass, bloom_w, bloom_h);

                const binding = [1]c.SDL_GPUTextureSamplerBinding{
                    .{ .texture = pp.bloom_a.?, .sampler = sampler },
                };
                c.SDL_BindGPUFragmentSamplers(pass, 0, &binding, 1);

                const params = BlurParams{ .direction = .{ texel_w, 0, 0, 0 } };
                c.SDL_PushGPUFragmentUniformData(cmd, 0, &params, @sizeOf(BlurParams));

                drawFullscreenTriangle(pass);
                c.SDL_EndGPURenderPass(pass);
            }

            // Vertical: bloom_b → bloom_a
            {
                const pass = beginFullscreenPass(cmd, pp.bloom_a.?) orelse return;
                c.SDL_BindGPUGraphicsPipeline(pass, pp.blur_pipeline.?);
                setFullscreenViewport(pass, bloom_w, bloom_h);

                const binding = [1]c.SDL_GPUTextureSamplerBinding{
                    .{ .texture = pp.bloom_b.?, .sampler = sampler },
                };
                c.SDL_BindGPUFragmentSamplers(pass, 0, &binding, 1);

                const params = BlurParams{ .direction = .{ 0, texel_h, 0, 0 } };
                c.SDL_PushGPUFragmentUniformData(cmd, 0, &params, @sizeOf(BlurParams));

                drawFullscreenTriangle(pass);
                c.SDL_EndGPURenderPass(pass);
            }
        }
    }

    // Final: Composite — HDR scene + bloom → swapchain (with tone mapping)
    // Always runs for tone mapping + gamma, even when bloom is disabled.
    {
        const pass = beginFullscreenPass(cmd, swapchain_tex) orelse return;
        c.SDL_BindGPUGraphicsPipeline(pass, pp.composite_pipeline.?);
        setFullscreenViewport(pass, sw_w, sw_h);

        const bindings = [2]c.SDL_GPUTextureSamplerBinding{
            .{ .texture = pp.hdr_texture.?, .sampler = sampler },
            .{ .texture = pp.bloom_a.?, .sampler = sampler },
        };
        c.SDL_BindGPUFragmentSamplers(pass, 0, &bindings, 2);

        const params = CompositeParams{ .params = .{ settings.intensity, settings.exposure, 0, 0 } };
        c.SDL_PushGPUFragmentUniformData(cmd, 0, &params, @sizeOf(CompositeParams));

        drawFullscreenTriangle(pass);
        c.SDL_EndGPURenderPass(pass);
    }
}
