// renderer.zig — GPU rendering: pipeline setup, render system, draw sorting.

const std = @import("std");
const math3d = @import("math3d.zig");
const components = @import("components.zig");
const geometry = @import("geometry.zig");
const ecs = @import("zig-ecs");
const engine_mod = @import("engine.zig");
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

const VertexUniforms = extern struct {
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
// GPU helpers
// ============================================================

fn createShader(device: *c.SDL_GPUDevice, spv: []const u8, msl: []const u8, stage: c.SDL_GPUShaderStage, num_uniform_buffers: u32) ?*c.SDL_GPUShader {
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
        .num_samplers = 0,
        .num_storage_textures = 0,
        .num_storage_buffers = 0,
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

    const vert_shader = createShader(device, vert_spv, vert_msl, c.SDL_GPU_SHADERSTAGE_VERTEX, 1) orelse {
        std.debug.print("Failed to create vertex shader: {s}\n", .{c.SDL_GetError()});
        return error.ShaderFailed;
    };
    defer c.SDL_ReleaseGPUShader(device, vert_shader);

    const frag_shader = createShader(device, frag_spv, frag_msl, c.SDL_GPU_SHADERSTAGE_FRAGMENT, 2) orelse {
        std.debug.print("Failed to create fragment shader: {s}\n", .{c.SDL_GetError()});
        return error.ShaderFailed;
    };
    defer c.SDL_ReleaseGPUShader(device, frag_shader);

    self.sample_count = config.msaa;
    self.swapchain_format = c.SDL_GetGPUSwapchainTextureFormat(device, self.sdl_window);
    const swapchain_format = self.swapchain_format;

    const vertex_attrs = [_]c.SDL_GPUVertexAttribute{
        .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3, .offset = @offsetOf(Vertex, "px") },
        .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3, .offset = @offsetOf(Vertex, "nx") },
    };

    const vertex_buf_desc = [_]c.SDL_GPUVertexBufferDescription{
        .{ .slot = 0, .pitch = @sizeOf(Vertex), .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX, .instance_step_rate = 0 },
    };

    const color_target_desc = [_]c.SDL_GPUColorTargetDescription{
        .{ .format = swapchain_format, .blend_state = std.mem.zeroes(c.SDL_GPUColorTargetBlendState) },
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
        self.msaa_color_texture = createMsaaColorTexture(device, swapchain_format, config.width, config.height, config.msaa) orelse {
            std.debug.print("Failed to create MSAA color texture: {s}\n", .{c.SDL_GetError()});
            return error.DepthTextureFailed;
        };
    }
    self.rt_w = config.width;
    self.rt_h = config.height;
}

// ============================================================
// Render system
// ============================================================

pub fn renderSystem(self: *Engine, device: *c.SDL_GPUDevice) void {
    const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse return;

    var swapchain_tex: ?*c.SDL_GPUTexture = null;
    var sw_w: u32 = 0;
    var sw_h: u32 = 0;
    if (!c.SDL_AcquireGPUSwapchainTexture(cmd, self.sdl_window, &swapchain_tex, &sw_w, &sw_h)) {
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
        return;
    }
    if (swapchain_tex == null) {
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
        return;
    }

    // Recreate render targets if swapchain dimensions changed
    if (sw_w != self.rt_w or sw_h != self.rt_h) {
        if (self.depth_texture) |dt| c.SDL_ReleaseGPUTexture(device, dt);
        self.depth_texture = createDepthTexture(device, sw_w, sw_h, self.sample_count);
        if (self.sample_count.isMultisample()) {
            if (self.msaa_color_texture) |mt| c.SDL_ReleaseGPUTexture(device, mt);
            self.msaa_color_texture = createMsaaColorTexture(device, self.swapchain_format, sw_w, sw_h, self.sample_count);
        }
        self.rt_w = sw_w;
        self.rt_h = sw_h;
        if (self.depth_texture == null) {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            return;
        }
    }

    // Find first directional light (or use defaults)
    var light_dir = [4]f32{ 0.4, 0.8, 0.4, 0.0 };
    {
        var light_view = self.registry.view(.{DirectionalLight}, .{});
        var light_iter = light_view.entityIterator();
        if (light_iter.next()) |light_entity| {
            const dl = light_view.getConst(light_entity);
            light_dir = .{ dl.dir_x, dl.dir_y, dl.dir_z, 0.0 };
        }
    }

    const default_material = MaterialUniforms{ .albedo = .{ 1.0, 1.0, 1.0, 1.0 } };
    const sw_w_f: f32 = @floatFromInt(sw_w);
    const sw_h_f: f32 = @floatFromInt(sw_h);

    const clear_color = c.SDL_FColor{ .r = self.clear_color[0], .g = self.clear_color[1], .b = self.clear_color[2], .a = self.clear_color[3] };
    const is_msaa = self.sample_count.isMultisample();

    // One render pass per camera — each clears depth, first clears color
    var cam_view = self.registry.view(.{ Position, Camera }, .{});
    var cam_iter = cam_view.entityIterator();
    var first_camera = true;
    while (cam_iter.next()) |cam_entity| {
        const cam_pos = cam_view.getConst(Position, cam_entity);
        const cam = cam_view.getConst(Camera, cam_entity);

        const color_load_op: c_uint = if (first_camera) c.SDL_GPU_LOADOP_CLEAR else c.SDL_GPU_LOADOP_LOAD;

        const color_target = if (is_msaa) c.SDL_GPUColorTargetInfo{
            .texture = self.msaa_color_texture,
            .mip_level = 0,
            .layer_or_depth_plane = 0,
            .clear_color = clear_color,
            .load_op = color_load_op,
            .store_op = c.SDL_GPU_STOREOP_RESOLVE_AND_STORE,
            .resolve_texture = swapchain_tex,
            .resolve_mip_level = 0,
            .resolve_layer = 0,
            .cycle = first_camera,
            .cycle_resolve_texture = false,
            .padding1 = 0,
            .padding2 = 0,
        } else c.SDL_GPUColorTargetInfo{
            .texture = swapchain_tex,
            .mip_level = 0,
            .layer_or_depth_plane = 0,
            .clear_color = clear_color,
            .load_op = color_load_op,
            .store_op = c.SDL_GPU_STOREOP_STORE,
            .resolve_texture = null,
            .resolve_mip_level = 0,
            .resolve_layer = 0,
            .cycle = first_camera,
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
            .cycle = first_camera,
            .clear_stencil = 0,
            .mip_level = 0,
            .layer = 0,
        };

        first_camera = false;

        const render_pass = c.SDL_BeginGPURenderPass(cmd, &color_target, 1, &depth_target) orelse continue;
        c.SDL_BindGPUGraphicsPipeline(render_pass, self.pipeline);

        // Set viewport and scissor for this camera
        const vp_x = cam.viewport_x * sw_w_f;
        const vp_y = cam.viewport_y * sw_h_f;
        const vp_w = cam.viewport_w * sw_w_f;
        const vp_h = cam.viewport_h * sw_h_f;
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

        const aspect: f32 = vp_w / vp_h;
        const proj = Mat4.perspective(cam.fov, aspect, cam.near, cam.far);

        const eye = Vec3.new(cam_pos.x, cam_pos.y, cam_pos.z);
        const view = if (self.registry.tryGet(LookAt, cam_entity)) |look_at| blk: {
            const target_entity: ecs.Entity = @bitCast(look_at.target);
            if (self.registry.tryGet(Position, target_entity)) |target_pos| {
                break :blk Mat4.lookAt(eye, Vec3.new(target_pos.x, target_pos.y, target_pos.z), Vec3.new(0, 1, 0));
            }
            break :blk Mat4.viewFromTransform(cam_pos.x, cam_pos.y, cam_pos.z, 0, 0, 0);
        } else if (self.registry.tryGet(Rotation, cam_entity)) |cam_rot| blk: {
            break :blk Mat4.viewFromTransform(cam_pos.x, cam_pos.y, cam_pos.z, cam_rot.x, cam_rot.y, cam_rot.z);
        } else Mat4.viewFromTransform(cam_pos.x, cam_pos.y, cam_pos.z, 0, 0, 0);

        const vp = Mat4.mul(proj, view);

        const scene_uniforms = SceneUniforms{
            .light_dir = light_dir,
            .camera_pos = .{ cam_pos.x, cam_pos.y, cam_pos.z, 0.0 },
            .fog_color = .{ self.fog_color[0], self.fog_color[1], self.fog_color[2], if (self.fog_enabled) 1.0 else 0.0 },
            .fog_params = .{ self.fog_start, self.fog_end, 0.0, 0.0 },
            .ambient = self.ambient_color,
        };
        c.SDL_PushGPUFragmentUniformData(cmd, 0, &scene_uniforms, @sizeOf(SceneUniforms));

        // Collect renderable entities and sort by mesh+material to minimize state changes
        var draw_count: u32 = 0;
        {
            var ecs_view = self.registry.view(.{ Position, Rotation, MeshHandle }, .{});
            var iter = ecs_view.entityIterator();
            while (iter.next()) |entity| {
                if (draw_count >= max_renderables) break;
                const mesh_id: u64 = ecs_view.getConst(MeshHandle, entity).id;
                const mat_id: u64 = if (self.registry.tryGet(MaterialHandle, entity)) |mh| mh.id else 0;
                self.draw_list[draw_count] = .{
                    .sort_key = (mesh_id << 32) | mat_id,
                    .entity = entity,
                };
                draw_count += 1;
            }
        }

        std.mem.sort(DrawEntry, self.draw_list[0..draw_count], {}, struct {
            fn lessThan(_: void, a: DrawEntry, b: DrawEntry) bool {
                return a.sort_key < b.sort_key;
            }
        }.lessThan);

        // Draw in sorted order
        var bound_mesh: ?u32 = null;
        var bound_mat: ?u32 = null;
        for (self.draw_list[0..draw_count]) |entry| {
            const pos = self.registry.getConst(Position, entry.entity);
            const rot = self.registry.getConst(Rotation, entry.entity);
            const mesh_id: u32 = @truncate(entry.sort_key >> 32);
            const mat_id: u32 = @truncate(entry.sort_key);
            const mesh = self.mesh_registry[mesh_id] orelse continue;

            if (bound_mesh == null or bound_mesh.? != mesh_id) {
                const binding = c.SDL_GPUBufferBinding{ .buffer = mesh.buffer, .offset = 0 };
                c.SDL_BindGPUVertexBuffers(render_pass, 0, &binding, 1);
                bound_mesh = mesh_id;
            }

            if (bound_mat == null or bound_mat.? != mat_id) {
                const mat_uniforms = if (self.material_registry[mat_id]) |mat|
                    MaterialUniforms{ .albedo = mat.albedo }
                else
                    default_material;
                c.SDL_PushGPUFragmentUniformData(cmd, 1, &mat_uniforms, @sizeOf(MaterialUniforms));
                bound_mat = mat_id;
            }

            const rotation = Mat4.mul(Mat4.mul(Mat4.rotateZ(rot.z), Mat4.rotateY(rot.y)), Mat4.rotateX(rot.x));
            const model = Mat4.mul(Mat4.translate(pos.x, pos.y, pos.z), rotation);
            const mvp = Mat4.mul(vp, model);

            const vert_uniforms = VertexUniforms{ .mvp = mvp.m, .model = model.m };
            c.SDL_PushGPUVertexUniformData(cmd, 0, &vert_uniforms, @sizeOf(VertexUniforms));
            c.SDL_DrawGPUPrimitives(render_pass, mesh.vertex_count, 1, 0, 0);
        }

        c.SDL_EndGPURenderPass(render_pass);
    }

    _ = c.SDL_SubmitGPUCommandBuffer(cmd);
}
