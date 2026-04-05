// renderer.zig — GPU rendering: pipeline setup, render system, draw sorting.

const std = @import("std");
const math3d = @import("math3d");
const components = @import("core_components");
const geometry = @import("geometry");
const ecs = @import("zig-ecs");
const engine_mod = @import("engine");
const Engine = engine_mod.Engine;
const c = engine_mod.c;
const Mat4 = math3d.Mat4;
const Vec3 = math3d.Vec3;

const Vertex = geometry.Vertex;
const Position = components.Position;
const Rotation = components.Rotation;
const Camera = components.Camera;
const DirectionalLight = components.DirectionalLight;
const LookAt = components.LookAt;
const Scale = components.Scale;
const MeshHandle = components.MeshHandle;
const MaterialHandle = components.MaterialHandle;

// ============================================================
// Compiled shaders (built from GLSL sources in shaders/)
// ============================================================

const vert_spv = @embedFile("shader_default_vert_spv");
const vert_msl = @embedFile("shader_default_vert_msl");
const frag_spv = @embedFile("shader_default_frag_spv");
const frag_msl = @embedFile("shader_default_frag_msl");

// ============================================================
// Uniform structs
// ============================================================

pub const InstanceData = extern struct {
    mvp: [4][4]f32,
    model: [4][4]f32,
};

const SceneUniforms = extern struct {
    light_dir: [4]f32,
    camera_pos: [4]f32,
    fog_color: [4]f32,
    fog_params: [4]f32,
    ambient: [4]f32,
};

const MaterialUniforms = extern struct {
    albedo: [4]f32,
    material_params: [4]f32 = .{ 0, 0.5, 0, 0 }, // .x = metallic, .y = roughness
    texture_flags: [4]f32 = .{ 0, 0, 0, 0 }, // .x = has_base_color, .y = has_metallic_roughness, .z = has_normal, .w = has_emissive
    emissive: [4]f32 = .{ 0, 0, 0, 0 }, // .xyz = emissive factor, .w = has_occlusion
};

// ============================================================
// Draw sorting
// ============================================================

pub const max_renderables = 16384;

pub const DrawEntry = struct {
    sort_key: u64, // mesh_id << 32 | material_id
    entity: ecs.Entity,
};

// ============================================================
// sRGB → HDR conversion (inverse of composite shader's tonemap + gamma)
// ============================================================

/// Convert a display-space (sRGB) color to the linear HDR value that the
/// composite shader's ACES tonemap + gamma will map back to the original.
fn srgbToHdr(srgb: f32, exposure: f32) f32 {
    // Undo gamma: sRGB ��� linear
    const linear = std.math.pow(f32, srgb, 2.2);
    // Undo ACES Narkowicz: solve  y = (x(2.51x+0.03)) / (x(2.43x+0.59)+0.14)
    // Rearranging: (2.43y - 2.51)x² + (0.59y - 0.03)x + 0.14y = 0
    // Use quadratic formula, take the smaller positive root.
    const y = linear;
    const a = 2.43 * y - 2.51;
    const b = 0.59 * y - 0.03;
    const cv = 0.14 * y;
    const discriminant = b * b - 4.0 * a * cv;
    if (discriminant < 0) return linear; // fallback
    const sq = @sqrt(discriminant);
    // a is negative for y < ~1.03, so the valid root is (-b + sqrt) / 2a
    const r1 = (-b + sq) / (2.0 * a);
    const r2 = (-b - sq) / (2.0 * a);
    const x = if (r1 >= 0 and (r2 < 0 or r1 < r2)) r1 else r2;
    // Undo exposure
    return if (exposure > 0) x / exposure else x;
}

fn srgbToHdr4(color: [4]f32, exposure: f32) [4]f32 {
    return .{
        srgbToHdr(color[0], exposure),
        srgbToHdr(color[1], exposure),
        srgbToHdr(color[2], exposure),
        color[3],
    };
}

fn srgbToHdr3(color: [3]f32, exposure: f32) [3]f32 {
    return .{
        srgbToHdr(color[0], exposure),
        srgbToHdr(color[1], exposure),
        srgbToHdr(color[2], exposure),
    };
}

// ============================================================
// GPU helpers
// ============================================================

fn createShader(device: *c.SDL_GPUDevice, spv: []const u8, msl: []const u8, stage: c.SDL_GPUShaderStage, num_uniform_buffers: u32, num_samplers: u32, num_storage_bufs: u32) ?*c.SDL_GPUShader {
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
        std.debug.print("No supported shader format found\n", .{});
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
        .num_storage_buffers = num_storage_bufs,
        .num_uniform_buffers = num_uniform_buffers,
        .props = 0,
    });
}

fn createDepthTexture(device: *c.SDL_GPUDevice, w: u32, h: u32, sample_count: engine_mod.SampleCount) ?*c.SDL_GPUTexture {
    return c.SDL_CreateGPUTexture(device, &c.SDL_GPUTextureCreateInfo{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = c.SDL_GPU_TEXTUREFORMAT_D32_FLOAT,
        .usage = c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET,
        .width = w,
        .height = h,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = sample_count.toRaw(),
        .props = 0,
    });
}

fn createMsaaColorTexture(device: *c.SDL_GPUDevice, format: c.SDL_GPUTextureFormat, w: u32, h: u32, sample_count: engine_mod.SampleCount) ?*c.SDL_GPUTexture {
    return c.SDL_CreateGPUTexture(device, &c.SDL_GPUTextureCreateInfo{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = format,
        .usage = c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET,
        .width = w,
        .height = h,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = sample_count.toRaw(),
        .props = 0,
    });
}

// ============================================================
// Pipeline initialization
// ============================================================

pub fn initPipeline(self: *Engine, config: engine_mod.Config) !void {
    const device = self.gpu_device.?;

    const vert_shader = createShader(device, vert_spv, vert_msl, c.SDL_GPU_SHADERSTAGE_VERTEX, 0, 0, 1) orelse {
        std.debug.print("Failed to create vertex shader: {s}\n", .{c.SDL_GetError()});
        return error.ShaderFailed;
    };
    defer c.SDL_ReleaseGPUShader(device, vert_shader);

    const frag_shader = createShader(device, frag_spv, frag_msl, c.SDL_GPU_SHADERSTAGE_FRAGMENT, 2, 5, 0) orelse {
        std.debug.print("Failed to create fragment shader: {s}\n", .{c.SDL_GetError()});
        return error.ShaderFailed;
    };
    defer c.SDL_ReleaseGPUShader(device, frag_shader);

    self.sample_count = config.msaa;
    self.swapchain_format = c.SDL_GetGPUSwapchainTextureFormat(device, self.sdl_window);

    // Scene pipeline renders to HDR float texture for post-processing
    const scene_format: c.SDL_GPUTextureFormat = c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT;

    const vertex_attrs = [_]c.SDL_GPUVertexAttribute{
        .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3, .offset = @offsetOf(Vertex, "px") },
        .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3, .offset = @offsetOf(Vertex, "nx") },
        .{ .location = 2, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(Vertex, "u") },
        .{ .location = 3, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4, .offset = @offsetOf(Vertex, "tx") },
    };

    const vertex_buf_desc = [_]c.SDL_GPUVertexBufferDescription{
        .{ .slot = 0, .pitch = @sizeOf(Vertex), .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX, .instance_step_rate = 0 },
    };

    const color_target_desc = [_]c.SDL_GPUColorTargetDescription{
        .{ .format = scene_format, .blend_state = std.mem.zeroes(c.SDL_GPUColorTargetBlendState) },
    };

    self.pipeline = c.SDL_CreateGPUGraphicsPipeline(device, &c.SDL_GPUGraphicsPipelineCreateInfo{
        .vertex_shader = vert_shader,
        .fragment_shader = frag_shader,
        .vertex_input_state = .{
            .vertex_buffer_descriptions = &vertex_buf_desc,
            .num_vertex_buffers = vertex_buf_desc.len,
            .vertex_attributes = &vertex_attrs,
            .num_vertex_attributes = vertex_attrs.len,
        },
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .rasterizer_state = .{
            .fill_mode = c.SDL_GPU_FILLMODE_FILL,
            .cull_mode = c.SDL_GPU_CULLMODE_BACK,
            .front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .enable_depth_bias = false,
            .enable_depth_clip = true,
            .padding1 = 0,
            .padding2 = 0,
        },
        .multisample_state = .{
            .sample_count = config.msaa.toRaw(),
            .sample_mask = 0,
            .enable_mask = false,
            .enable_alpha_to_coverage = false,
            .padding2 = 0,
            .padding3 = 0,
        },
        .depth_stencil_state = .{
            .compare_op = c.SDL_GPU_COMPAREOP_LESS,
            .back_stencil_state = std.mem.zeroes(c.SDL_GPUStencilOpState),
            .front_stencil_state = std.mem.zeroes(c.SDL_GPUStencilOpState),
            .compare_mask = 0,
            .write_mask = 0,
            .enable_depth_test = true,
            .enable_depth_write = true,
            .enable_stencil_test = false,
            .padding1 = 0,
            .padding2 = 0,
            .padding3 = 0,
        },
        .target_info = .{
            .color_target_descriptions = &color_target_desc,
            .num_color_targets = color_target_desc.len,
            .depth_stencil_format = c.SDL_GPU_TEXTUREFORMAT_D32_FLOAT,
            .has_depth_stencil_target = true,
            .padding1 = 0,
            .padding2 = 0,
            .padding3 = 0,
        },
        .props = 0,
    }) orelse {
        std.debug.print("Failed to create pipeline: {s}\n", .{c.SDL_GetError()});
        return error.PipelineFailed;
    };

    // Render targets (depth + optional MSAA color)
    self.depth_texture = createDepthTexture(device, config.width, config.height, config.msaa) orelse {
        std.debug.print("Failed to create depth texture: {s}\n", .{c.SDL_GetError()});
        return error.DepthTextureFailed;
    };
    if (config.msaa.isMultisample()) {
        self.msaa_color_texture = createMsaaColorTexture(device, scene_format, config.width, config.height, config.msaa) orelse {
            std.debug.print("Failed to create MSAA color texture: {s}\n", .{c.SDL_GetError()});
            return error.DepthTextureFailed;
        };
    }
    self.rt_w = config.width;
    self.rt_h = config.height;
}

// ============================================================
// Render system — decomposed into focused phases
// ============================================================

fn resolveTexture(self: *Engine, tex_id: ?u32, dummy: *c.SDL_GPUTexture) *c.SDL_GPUTexture {
    if (tex_id) |id| {
        if (self.assets.texture_registry[id]) |tex| return tex.texture;
    }
    return dummy;
}

/// Query the ECS for the first directional light, or return defaults.
fn gatherLights(registry: *ecs.Registry) [4]f32 {
    var light_dir = [4]f32{ 0.4, 0.8, 0.4, 0.0 };
    var light_view = registry.view(.{DirectionalLight}, .{});
    var light_iter = light_view.entityIterator();
    if (light_iter.next()) |light_entity| {
        const dl = light_view.getConst(light_entity);
        const len_sq = dl.dir_x * dl.dir_x + dl.dir_y * dl.dir_y + dl.dir_z * dl.dir_z;
        if (len_sq > 1e-8) {
            light_dir = .{ dl.dir_x, dl.dir_y, dl.dir_z, 0.0 };
        }
    }
    return light_dir;
}

/// Collect all renderable entities into the draw list, sorted by mesh+material
/// to minimize GPU state changes. Uses a zig-ecs group for automatic entity
/// set maintenance — no per-frame filtering needed. Returns the number of entries.
fn buildDrawList(self: *Engine) u32 {
    var draw_count: u32 = 0;
    // Non-owning group: zig-ecs maintains this entity set automatically via
    // signals on component add/remove. Calling group() is a cached hash lookup.
    var group = self.registry.group(.{}, .{ Position, Rotation, MeshHandle }, .{});
    for (group.data()) |entity| {
        if (draw_count >= max_renderables) break;
        const mesh_id: u64 = self.registry.getConst(MeshHandle, entity).id;
        const mat_id: u64 = if (self.registry.tryGet(MaterialHandle, entity)) |mh| mh.id else 0;
        self.draw_list[draw_count] = .{
            .sort_key = (mesh_id << 32) | mat_id,
            .entity = entity,
        };
        draw_count += 1;
    }

    std.mem.sort(DrawEntry, self.draw_list[0..draw_count], {}, struct {
        fn lessThan(_: void, a: DrawEntry, b: DrawEntry) bool {
            return a.sort_key < b.sort_key;
        }
    }.lessThan);

    return draw_count;
}

/// Count the number of unique batches (distinct sort keys) in the draw list.
pub fn countBatches(self: *Engine, draw_count: u32) u32 {
    if (draw_count == 0) return 0;
    var batches: u32 = 1;
    var i: u32 = 1;
    while (i < draw_count) : (i += 1) {
        if (self.draw_list[i].sort_key != self.draw_list[i - 1].sort_key) batches += 1;
    }
    return batches;
}

/// Upload per-instance data (model + MVP matrices) to the GPU storage buffer.
/// Must be called before the render pass within the same command buffer.
fn uploadInstances(self: *Engine, cmd: *c.SDL_GPUCommandBuffer, vp: Mat4, draw_count: u32) void {
    if (draw_count == 0) return;
    const transfer = self.instance_transfer orelse return;
    const gpu_buf = self.instance_buffer orelse return;

    // Map transfer buffer and fill instance data
    const ptr = c.SDL_MapGPUTransferBuffer(self.gpu_device.?, transfer, true) orelse return;
    const instances: [*]InstanceData = @ptrCast(@alignCast(ptr));

    for (self.draw_list[0..draw_count], 0..) |entry, i| {
        const pos = self.registry.getConst(Position, entry.entity);
        const rot = self.registry.getConst(Rotation, entry.entity);
        const rotation = Mat4.mul(Mat4.mul(Mat4.rotateZ(rot.z), Mat4.rotateY(rot.y)), Mat4.rotateX(rot.x));
        const scl = if (self.registry.tryGet(Scale, entry.entity)) |s|
            Mat4.scale(s.x, s.y, s.z)
        else
            Mat4.identity();
        const model = Mat4.mul(Mat4.translate(pos.x, pos.y, pos.z), Mat4.mul(rotation, scl));
        const mvp = Mat4.mul(vp, model);
        instances[i] = .{ .mvp = mvp.m, .model = model.m };
    }

    c.SDL_UnmapGPUTransferBuffer(self.gpu_device.?, transfer);

    // Upload to GPU via copy pass
    const data_size: u32 = draw_count * @sizeOf(InstanceData);
    const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse return;
    c.SDL_UploadToGPUBuffer(copy_pass, &c.SDL_GPUTransferBufferLocation{
        .transfer_buffer = transfer,
        .offset = 0,
    }, &c.SDL_GPUBufferRegion{
        .buffer = gpu_buf,
        .offset = 0,
        .size = data_size,
    }, true);
    c.SDL_EndGPUCopyPass(copy_pass);
}

/// Submit batched instanced draw calls. The draw list is sorted by mesh+material,
/// so consecutive entries with the same sort_key form a batch drawn in one call.
fn submitDrawCalls(
    self: *Engine,
    cmd: *c.SDL_GPUCommandBuffer,
    render_pass: *c.SDL_GPURenderPass,
    draw_count: u32,
) void {
    if (draw_count == 0) return;
    const default_material = MaterialUniforms{ .albedo = .{ 1, 1, 1, 1 } };

    // Bind the instance storage buffer
    const buf_ptr = [1]*c.SDL_GPUBuffer{self.instance_buffer.?};
    c.SDL_BindGPUVertexStorageBuffers(render_pass, 0, &buf_ptr, 1);

    var batch_start: u32 = 0;
    while (batch_start < draw_count) {
        const sort_key = self.draw_list[batch_start].sort_key;
        var batch_end: u32 = batch_start + 1;
        while (batch_end < draw_count and self.draw_list[batch_end].sort_key == sort_key) {
            batch_end += 1;
        }
        const instance_count = batch_end - batch_start;

        const mesh_id: u32 = @truncate(sort_key >> 32);
        const mat_id: u32 = @truncate(sort_key);
        const mesh = self.assets.mesh_registry[mesh_id] orelse {
            batch_start = batch_end;
            continue;
        };

        // Bind mesh
        const binding = c.SDL_GPUBufferBinding{ .buffer = mesh.vertex_buffer, .offset = 0 };
        c.SDL_BindGPUVertexBuffers(render_pass, 0, &binding, 1);
        if (mesh.index_buffer) |ib| {
            c.SDL_BindGPUIndexBuffer(render_pass, &c.SDL_GPUBufferBinding{ .buffer = ib, .offset = 0 }, c.SDL_GPU_INDEXELEMENTSIZE_32BIT);
        }

        // Bind material
        const sampler = self.assets.default_sampler.?;
        const dummy = self.assets.dummy_texture.?;

        if (self.assets.material_registry[mat_id]) |mat| {
            const has_bc: f32 = if (mat.base_color_texture != null) 1.0 else 0.0;
            const has_mr: f32 = if (mat.metallic_roughness_texture != null) 1.0 else 0.0;
            const has_nm: f32 = if (mat.normal_texture != null) 1.0 else 0.0;
            const has_em: f32 = if (mat.emissive_texture != null) 1.0 else 0.0;
            const has_ao: f32 = if (mat.occlusion_texture != null) 1.0 else 0.0;

            const mat_uniforms = MaterialUniforms{
                .albedo = mat.albedo,
                .material_params = .{ mat.metallic, mat.roughness, 0, 0 },
                .texture_flags = .{ has_bc, has_mr, has_nm, has_em },
                .emissive = .{ mat.emissive[0], mat.emissive[1], mat.emissive[2], has_ao },
            };
            c.SDL_PushGPUFragmentUniformData(cmd, 1, &mat_uniforms, @sizeOf(MaterialUniforms));

            const tex_bindings = [5]c.SDL_GPUTextureSamplerBinding{
                .{ .texture = resolveTexture(self, mat.base_color_texture, dummy), .sampler = sampler },
                .{ .texture = resolveTexture(self, mat.metallic_roughness_texture, dummy), .sampler = sampler },
                .{ .texture = resolveTexture(self, mat.normal_texture, dummy), .sampler = sampler },
                .{ .texture = resolveTexture(self, mat.emissive_texture, dummy), .sampler = sampler },
                .{ .texture = resolveTexture(self, mat.occlusion_texture, dummy), .sampler = sampler },
            };
            c.SDL_BindGPUFragmentSamplers(render_pass, 0, &tex_bindings, 5);
        } else {
            c.SDL_PushGPUFragmentUniformData(cmd, 1, &default_material, @sizeOf(MaterialUniforms));
            const tex_bindings = [5]c.SDL_GPUTextureSamplerBinding{
                .{ .texture = dummy, .sampler = sampler },
                .{ .texture = dummy, .sampler = sampler },
                .{ .texture = dummy, .sampler = sampler },
                .{ .texture = dummy, .sampler = sampler },
                .{ .texture = dummy, .sampler = sampler },
            };
            c.SDL_BindGPUFragmentSamplers(render_pass, 0, &tex_bindings, 5);
        }

        // Instanced draw — batch_start is the first instance index
        if (mesh.index_buffer != null) {
            c.SDL_DrawGPUIndexedPrimitives(render_pass, mesh.index_count, instance_count, 0, 0, batch_start);
        } else {
            c.SDL_DrawGPUPrimitives(render_pass, mesh.vertex_count, instance_count, 0, batch_start);
        }

        batch_start = batch_end;
    }
}

/// Cached per-frame scene data (computed once, shared across cameras).
pub const FrameContext = struct {
    light_dir: [4]f32,
    draw_count: u32,
};

/// Prepare shared scene data for the frame: gather lights, build sorted draw list,
/// and resize render targets if needed.
pub fn prepareFrame(self: *Engine, w: u32, h: u32) FrameContext {
    const device = self.gpu_device.?;
    const hdr_format: c.SDL_GPUTextureFormat = c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT;

    // Recreate render targets if dimensions changed
    if (w != self.rt_w or h != self.rt_h) {
        if (self.depth_texture) |old_dt| c.SDL_ReleaseGPUTexture(device, old_dt);
        self.depth_texture = createDepthTexture(device, w, h, self.sample_count);
        if (self.sample_count.isMultisample()) {
            if (self.msaa_color_texture) |mt| c.SDL_ReleaseGPUTexture(device, mt);
            self.msaa_color_texture = createMsaaColorTexture(device, hdr_format, w, h, self.sample_count);
        }
        self.rt_w = w;
        self.rt_h = h;
    }

    return .{
        .light_dir = gatherLights(&self.registry),
        .draw_count = buildDrawList(self),
    };
}

/// Render the scene from a single camera into the given color target texture.
fn computeVP(self: *Engine, cam_entity: ecs.Entity, w: u32, h: u32) Mat4 {
    const cam_pos = self.registry.getConst(Position, cam_entity);
    const cam = self.registry.getConst(Camera, cam_entity);
    const w_f: f32 = @floatFromInt(w);
    const h_f: f32 = @floatFromInt(h);
    const vp_w = cam.viewport_w * w_f;
    const vp_h = cam.viewport_h * h_f;
    const aspect: f32 = vp_w / vp_h;
    const proj = Mat4.perspective(cam.fov, aspect, cam.near, cam.far);

    const eye = Vec3.new(cam_pos.x, cam_pos.y, cam_pos.z);
    const view = if (self.registry.tryGet(LookAt, cam_entity)) |look_at| blk: {
        const target_entity: ecs.Entity = @bitCast(look_at.target);
        if (self.registry.valid(target_entity)) {
            if (self.registry.tryGet(Position, target_entity)) |target_pos| {
                break :blk Mat4.lookAt(eye, Vec3.new(target_pos.x, target_pos.y, target_pos.z), Vec3.new(0, 1, 0));
            }
        }
        break :blk Mat4.viewFromTransform(cam_pos.x, cam_pos.y, cam_pos.z, 0, 0, 0);
    } else if (self.registry.tryGet(Rotation, cam_entity)) |cam_rot| blk: {
        break :blk Mat4.viewFromTransform(cam_pos.x, cam_pos.y, cam_pos.z, cam_rot.x, cam_rot.y, cam_rot.z);
    } else Mat4.viewFromTransform(cam_pos.x, cam_pos.y, cam_pos.z, 0, 0, 0);

    return Mat4.mul(proj, view);
}

/// Compute per-instance matrices and upload to GPU. Must be called before executeScenePass.
pub fn uploadInstanceData(self: *Engine, cmd: *c.SDL_GPUCommandBuffer, cam_entity: ecs.Entity, w: u32, h: u32, frame: FrameContext) void {
    const vp = computeVP(self, cam_entity, w, h);
    uploadInstances(self, cmd, vp, frame.draw_count);
}

/// Execute the scene render pass (assumes instance data already uploaded).
pub fn executeScenePass(
    self: *Engine,
    cmd: *c.SDL_GPUCommandBuffer,
    cam_entity: ecs.Entity,
    color_target_tex: *c.SDL_GPUTexture,
    w: u32,
    h: u32,
    frame: FrameContext,
    exposure: f32,
) void {
    if (self.depth_texture == null) return;

    const cam_pos = self.registry.getConst(Position, cam_entity);
    const cam = self.registry.getConst(Camera, cam_entity);
    const is_msaa = self.sample_count.isMultisample();

    const hdr_clear = srgbToHdr4(self.clear_color, exposure);
    const clear_color = c.SDL_FColor{ .r = hdr_clear[0], .g = hdr_clear[1], .b = hdr_clear[2], .a = 1000.0 };

    const color_target = if (is_msaa) c.SDL_GPUColorTargetInfo{
        .texture = self.msaa_color_texture,
        .mip_level = 0,
        .layer_or_depth_plane = 0,
        .clear_color = clear_color,
        .load_op = c.SDL_GPU_LOADOP_CLEAR,
        .store_op = c.SDL_GPU_STOREOP_RESOLVE_AND_STORE,
        .resolve_texture = color_target_tex,
        .resolve_mip_level = 0,
        .resolve_layer = 0,
        .cycle = true,
        .cycle_resolve_texture = false,
        .padding1 = 0,
        .padding2 = 0,
    } else c.SDL_GPUColorTargetInfo{
        .texture = color_target_tex,
        .mip_level = 0,
        .layer_or_depth_plane = 0,
        .clear_color = clear_color,
        .load_op = c.SDL_GPU_LOADOP_CLEAR,
        .store_op = c.SDL_GPU_STOREOP_STORE,
        .resolve_texture = null,
        .resolve_mip_level = 0,
        .resolve_layer = 0,
        .cycle = true,
        .cycle_resolve_texture = false,
        .padding1 = 0,
        .padding2 = 0,
    };

    const depth_target = c.SDL_GPUDepthStencilTargetInfo{
        .texture = self.depth_texture,
        .clear_depth = 1.0,
        .load_op = c.SDL_GPU_LOADOP_CLEAR,
        .store_op = c.SDL_GPU_STOREOP_DONT_CARE,
        .stencil_load_op = c.SDL_GPU_LOADOP_DONT_CARE,
        .stencil_store_op = c.SDL_GPU_STOREOP_DONT_CARE,
        .cycle = true,
        .clear_stencil = 0,
        .mip_level = 0,
        .layer = 0,
    };

    const render_pass = c.SDL_BeginGPURenderPass(cmd, &color_target, 1, &depth_target) orelse return;
    c.SDL_BindGPUGraphicsPipeline(render_pass, self.pipeline);

    const w_f: f32 = @floatFromInt(w);
    const h_f: f32 = @floatFromInt(h);
    const vp_x = cam.viewport_x * w_f;
    const vp_y = cam.viewport_y * h_f;
    const vp_w = cam.viewport_w * w_f;
    const vp_h = cam.viewport_h * h_f;
    c.SDL_SetGPUViewport(render_pass, &c.SDL_GPUViewport{
        .x = vp_x,
        .y = vp_y,
        .w = vp_w,
        .h = vp_h,
        .min_depth = 0.0,
        .max_depth = 1.0,
    });
    c.SDL_SetGPUScissor(render_pass, &c.SDL_Rect{
        .x = @intFromFloat(vp_x),
        .y = @intFromFloat(vp_y),
        .w = @intFromFloat(vp_w),
        .h = @intFromFloat(vp_h),
    });

    const hdr_fog = srgbToHdr3(self.fog_color, exposure);
    const scene_uniforms = SceneUniforms{
        .light_dir = frame.light_dir,
        .camera_pos = .{ cam_pos.x, cam_pos.y, cam_pos.z, 0.0 },
        .fog_color = .{ hdr_fog[0], hdr_fog[1], hdr_fog[2], if (self.fog_enabled) 1.0 else 0.0 },
        .fog_params = .{ self.fog_start, self.fog_end, 0.0, 0.0 },
        .ambient = self.ambient_color,
    };
    c.SDL_PushGPUFragmentUniformData(cmd, 0, &scene_uniforms, @sizeOf(SceneUniforms));

    submitDrawCalls(self, cmd, render_pass, frame.draw_count);
    c.SDL_EndGPURenderPass(render_pass);
}
