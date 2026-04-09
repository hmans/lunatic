// renderer.zig — GPU rendering: pipeline setup, render system, draw sorting.

const std = @import("std");
const math3d = @import("math3d");
const components = @import("core_components");
const geometry = @import("geometry");
const ecs = @import("zflecs");
const queryInit = engine_mod.queryInit;
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
const PointLight = components.PointLight;
const SpotLight = components.SpotLight;
const LookAt = components.LookAt;
const Scale = components.Scale;
const MeshHandle = components.MeshHandle;
const MaterialHandle = components.MaterialHandle;
const ShadowCaster = components.ShadowCaster;
const ShadowReceiver = components.ShadowReceiver;

// ============================================================
// Compiled shaders (built from GLSL sources in shaders/)
// ============================================================

const vert_spv = @embedFile("shader_default_vert_spv");
const vert_msl = @embedFile("shader_default_vert_msl");
const frag_spv = @embedFile("shader_default_frag_spv");
const frag_msl = @embedFile("shader_default_frag_msl");
const shadow_vert_spv = @embedFile("shader_shadow_vert_spv");
const shadow_vert_msl = @embedFile("shader_shadow_vert_msl");
const shadow_frag_spv = @embedFile("shader_shadow_frag_spv");
const shadow_frag_msl = @embedFile("shader_shadow_frag_msl");
const instance_setup_spv = @embedFile("shader_instance_setup_comp_spv");
const instance_setup_msl = @embedFile("shader_instance_setup_comp_msl");
const fog_inject_spv = @embedFile("shader_fog_inject_comp_spv");
const fog_inject_msl = @embedFile("shader_fog_inject_comp_msl");

// ============================================================
// Uniform structs
// ============================================================

pub const InstanceData = extern struct {
    mvp: [4][4]f32,
    model: [4][4]f32,
    flags: [4]f32, // .x = receives_shadow, .yzw = 1/scale² (for normal matrix)
};

const SceneUniforms = extern struct {
    light_dir: [4]f32,
    camera_pos: [4]f32,
    fog_color: [4]f32,
    fog_params: [4]f32,
    ambient: [4]f32,
    light_color: [4]f32, // xyz = directional light color * intensity
    cluster_grid: [4]f32, // x=nx, y=ny, z=nz, w=num_lights
    cluster_depth: [4]f32, // x=near, y=far, z=log(far/near)
    cluster_screen: [4]f32, // x=screen_w, y=screen_h, z=tiles_per_pixel_x, w=tiles_per_pixel_y
};

const MaterialUniforms = extern struct {
    albedo: [4]f32,
    material_params: [4]f32 = .{ 0, 0.5, 0, 0 }, // .x = metallic, .y = roughness
    texture_flags: [4]f32 = .{ 0, 0, 0, 0 }, // .x = has_base_color, .y = has_metallic_roughness, .z = has_normal, .w = has_emissive
    emissive: [4]f32 = .{ 0, 0, 0, 0 }, // .xyz = emissive factor, .w = has_occlusion
};

// ============================================================
// GPU-driven: entity data for compute shader instance setup
// ============================================================

/// Raw per-entity transform data uploaded to GPU for the instance setup compute
/// shader. Contains position, euler rotation (degrees), scale, and flags.
/// 48 bytes per entity — matches the EntityData struct in instance_setup.comp.
pub const EntityData = extern struct {
    position: [4]f32, // xyz = world position, w = receives_shadow
    rotation: [4]f32, // xyz = euler angles (degrees), w = unused
    scale_flags: [4]f32, // xyz = scale, w = is_shadow_caster
};

/// Uniforms pushed to the instance setup compute shader each dispatch.
/// Must match ComputeUniforms in instance_setup.comp (std140 layout).
const ComputeUniforms = extern struct {
    vp: [4][4]f32, // View-projection matrix for this pass
    frustum_planes: [6][4]f32, // 6 frustum planes: xyz = normal, w = distance
    entity_count: u32, // Number of entities to process
    shadow_pass: u32, // 0 = scene pass, 1 = shadow pass
    frustum_cull: u32, // 0 = no culling, 1 = cull against frustum
    occlusion_cull: u32, // 0 = disabled, 1 = test against HiZ pyramid
    prev_vp: [4][4]f32, // Previous frame's VP matrix (for HiZ reprojection)
    prev_camera_pos: [4]f32, // xyz = previous frame camera world position
    hiz_params: [4]f32, // x = hiz_width, y = hiz_height, z = max_mip, w = unused
};

/// Extract the 6 frustum planes from a view-projection matrix.
/// Each plane is (nx, ny, nz, d) where dot(n, p) + d >= 0 means inside.
/// Uses the Griggs-Hartmann method: planes from rows of the VP matrix.
fn extractFrustumPlanes(vp: Mat4) [6][4]f32 {
    // VP is column-major: vp.m[col][row].
    // Row i of VP = (vp.m[0][i], vp.m[1][i], vp.m[2][i], vp.m[3][i]).
    var planes: [6][4]f32 = undefined;

    // Left:   row3 + row0
    // Right:  row3 - row0
    // Bottom: row3 + row1
    // Top:    row3 - row1
    // Near:   row3 + row2
    // Far:    row3 - row2
    const combos = [6][2]struct { row: usize, sign: f32 }{
        .{ .{ .row = 0, .sign = 1.0 }, .{ .row = 3, .sign = 1.0 } }, // left
        .{ .{ .row = 0, .sign = -1.0 }, .{ .row = 3, .sign = 1.0 } }, // right
        .{ .{ .row = 1, .sign = 1.0 }, .{ .row = 3, .sign = 1.0 } }, // bottom
        .{ .{ .row = 1, .sign = -1.0 }, .{ .row = 3, .sign = 1.0 } }, // top
        .{ .{ .row = 2, .sign = 1.0 }, .{ .row = 3, .sign = 1.0 } }, // near
        .{ .{ .row = 2, .sign = -1.0 }, .{ .row = 3, .sign = 1.0 } }, // far
    };

    for (0..6) |i| {
        const r_a = combos[i][0].row;
        const s_a = combos[i][0].sign;
        const r_b = combos[i][1].row;

        var plane: [4]f32 = undefined;
        for (0..4) |col| {
            plane[col] = vp.m[col][r_b] + s_a * vp.m[col][r_a];
        }

        // Normalize the plane so distance tests are in world units
        const len = @sqrt(plane[0] * plane[0] + plane[1] * plane[1] + plane[2] * plane[2]);
        if (len > 1e-8) {
            const inv = 1.0 / len;
            plane[0] *= inv;
            plane[1] *= inv;
            plane[2] *= inv;
            plane[3] *= inv;
        }
        planes[i] = plane;
    }

    return planes;
}

// ============================================================
// GPU-driven: indirect draw structs
// ============================================================

/// Maximum number of distinct mesh+material batches per frame.
pub const max_batches: u32 = 256;

/// Per-batch info uploaded to GPU for the compute shader.
/// Tells each entity where its batch's instance region starts.
pub const BatchInfo = extern struct {
    instance_offset: u32, // first instance index in the compacted output buffer
};

/// Matches SDL_GPUIndexedIndirectDrawCommand exactly. The compute shader
/// atomically increments num_instances; all other fields are set by CPU.
pub const IndirectDrawCommand = extern struct {
    num_indices: u32,
    num_instances: u32, // written by compute shader via atomicAdd
    first_index: u32,
    vertex_offset: i32,
    first_instance: u32,
};

/// GPU-written culling statistics. The compute shader atomically increments
/// these counters during the scene pass. Read back by CPU one frame later
/// (via download to transfer buffer) for the debug stats panel.
pub const CullingStats = extern struct {
    visible_count: u32 = 0,
    frustum_culled: u32 = 0,
    occlusion_culled: u32 = 0,
};

/// CPU-side batch descriptor computed from the sorted draw list each frame.
/// Used to upload batch info and build indirect draw commands.
pub const BatchDescriptor = struct {
    mesh_id: u32,
    material_id: u32,
    entity_start: u32, // first entity in this batch (index into draw_list)
    entity_count: u32, // number of entities in this batch
    instance_offset: u32, // cumulative offset in the compacted instance buffer
};

// ============================================================
// Cascaded Shadow Maps
// ============================================================

pub const cascade_count: u32 = 4;
pub const shadow_atlas_size: u32 = 4096;
pub const shadow_cascade_size: u32 = 2048;
const cascade_lambda: f32 = 0.5;

pub const ShadowUniforms = extern struct {
    light_vp: [cascade_count][4][4]f32, // 4 cascade light VP matrices
    cascade_splits: [4]f32, // view-space distances for cascade boundaries
    shadow_params: [4]f32, // .x = atlas_size, .y = cascade_size, .z = bias, .w = enabled
};

// ============================================================
// Clustered lighting constants and GPU types
// ============================================================

pub const cluster_x: u32 = 16;
pub const cluster_y: u32 = 9;
pub const cluster_z: u32 = 24;
pub const num_clusters: u32 = cluster_x * cluster_y * cluster_z;
pub const max_lights: u32 = 256;
pub const max_light_indices: u32 = 256 * 1024;

/// GPU light struct — 64 bytes, matches GLSL std430 layout.
pub const GPULight = extern struct {
    pos_radius: [4]f32,
    color_type: [4]f32, // xyz = color*intensity, w = type (0=point, 1=spot)
    dir_spot: [4]f32, // xyz = direction (spot only)
    cone_params: [4]f32, // x = cos(inner), y = cos(outer)
};

/// Per-cluster offset+count, maps to uvec2 in GLSL.
pub const ClusterInfo = extern struct {
    offset: u32,
    count: u32,
};

// ============================================================
// Draw sorting
// ============================================================

pub const max_renderables = 16384;

pub const DrawEntry = struct {
    sort_key: u64, // mesh_id << 32 | material_id
    entity: ecs.entity_t,
};

// ============================================================
// sRGB → HDR conversion (inverse of composite shader's AgX tonemap + gamma)
// ============================================================
//
// User-specified sRGB colors (clear color, fog color) need to be pre-transformed
// so they round-trip correctly through the composite shader's AgX tonemapper.
// Given a target sRGB display color, we find the linear HDR value that, after
// exposure + AgX + gamma, produces that exact color on screen.
//
// Since the AgX pipeline (3x3 matrix → log → 6th-degree polynomial → 3x3 matrix)
// is not analytically invertible, we use Newton-Raphson iteration on each channel
// of the full forward pipeline. 8 iterations converge to machine precision for
// any input in [0, 1]. This runs once at scene setup, not per-frame.

/// Forward AgX tonemapping for a single RGB color (matches composite.frag exactly).
fn agxForward(rgb: [3]f32) [3]f32 {
    // Pre-scale to match composite.frag's AgX brightness compensation
    const prescaled = [3]f32{ rgb[0] * 0.85, rgb[1] * 0.85, rgb[2] * 0.85 };
    // Step 1: linear sRGB → AgX log-space (inset matrix)
    var ch = [3]f32{
        0.842479 * prescaled[0] + 0.0423738 * prescaled[1] + 0.0423738 * prescaled[2],
        0.0784336 * prescaled[0] + 0.878236 * prescaled[1] + 0.0784336 * prescaled[2],
        0.0792238 * prescaled[0] + 0.0791661 * prescaled[1] + 0.879142 * prescaled[2],
    };

    // Step 2: log2 encoding to [0,1]
    const log_min: f32 = -12.47393;
    const log_max: f32 = 4.026069;
    for (&ch) |*v| {
        v.* = @log2(@max(v.*, 1e-10));
        v.* = (v.* - log_min) / (log_max - log_min);
        v.* = std.math.clamp(v.*, 0.0, 1.0);
    }

    // Step 3: AgX base contrast curve (6th-degree polynomial)
    for (&ch) |*v| {
        const x = v.*;
        const x2 = x * x;
        const x4 = x2 * x2;
        v.* = 15.5 * x4 * x2 - 40.14 * x4 * x + 31.96 * x4 - 6.868 * x2 * x + 0.4298 * x2 + 0.1191 * x - 0.00232;
    }

    // Step 4: AgX log-space → linear sRGB (outset matrix)
    const r = 1.19687 * ch[0] + -0.0528968 * ch[1] + -0.0529716 * ch[2];
    const g = -0.0980208 * ch[0] + 1.15190 * ch[1] + -0.0980434 * ch[2];
    const b = -0.0990297 * ch[0] + -0.0989612 * ch[1] + 1.15107 * ch[2];

    return .{
        std.math.clamp(r, 0.0, 1.0),
        std.math.clamp(g, 0.0, 1.0),
        std.math.clamp(b, 0.0, 1.0),
    };
}

/// Inverse AgX + gamma + exposure for a single channel, via Newton-Raphson.
/// Finds x such that: gamma(agxForward([x,x,x] * exposure)[channel]) ≈ target_srgb
/// We actually work on the full RGB triple to account for the 3x3 matrix coupling.
fn srgbToHdr3(srgb: [3]f32, exposure: f32) [3]f32 {
    // Target: the linear values after undoing gamma
    var target: [3]f32 = undefined;
    for (0..3) |i| {
        target[i] = std.math.pow(f32, srgb[i], 2.2);
    }

    // Initial guess: start with the linear value (pre-exposure)
    var x: [3]f32 = undefined;
    const exp_safe = if (exposure > 0) exposure else 1.0;
    for (0..3) |i| {
        x[i] = target[i] / exp_safe;
    }

    // Newton-Raphson: iterate to find x where agxForward(x * exposure) = target
    for (0..12) |_| {
        var exposed: [3]f32 = undefined;
        for (0..3) |i| exposed[i] = x[i] * exp_safe;

        const fwd = agxForward(exposed);

        // Numerical derivative: d(agxForward)/dx per channel
        const eps: f32 = 1e-4;
        var dx: [3]f32 = undefined;
        for (0..3) |i| {
            var nudged = exposed;
            nudged[i] += eps;
            const fwd_nudged = agxForward(nudged);
            const deriv = (fwd_nudged[i] - fwd[i]) / eps;
            const err = fwd[i] - target[i];
            // Guard against zero derivative (flat regions of the curve)
            if (@abs(deriv) > 1e-8) {
                dx[i] = err / deriv;
            } else {
                dx[i] = 0;
            }
        }

        for (0..3) |i| {
            x[i] -= dx[i] / exp_safe;
            x[i] = @max(x[i], 0.0);
        }
    }

    return x;
}

fn srgbToHdr4(color: [4]f32, exposure: f32) [4]f32 {
    const rgb = srgbToHdr3(.{ color[0], color[1], color[2] }, exposure);
    return .{ rgb[0], rgb[1], rgb[2], color[3] };
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

/// Create a GPU compute pipeline from pre-compiled SPIR-V and MSL shader code.
/// The pipeline is configured with the specified resource counts and workgroup size.
fn createComputePipeline(
    device: *c.SDL_GPUDevice,
    spv: []const u8,
    msl: []const u8,
    num_readonly_storage_buffers: u32,
    num_readwrite_storage_buffers: u32,
    num_uniform_buffers: u32,
    num_samplers: u32,
    threadcount_x: u32,
    threadcount_y: u32,
    threadcount_z: u32,
) ?*c.SDL_GPUComputePipeline {
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
        std.debug.print("No supported shader format for compute pipeline\n", .{});
        return null;
    }

    return c.SDL_CreateGPUComputePipeline(device, &c.SDL_GPUComputePipelineCreateInfo{
        .code_size = code_size,
        .code = code,
        .entrypoint = entrypoint,
        .format = format,
        .num_samplers = num_samplers,
        .num_readonly_storage_textures = 0,
        .num_readonly_storage_buffers = num_readonly_storage_buffers,
        .num_readwrite_storage_textures = 0,
        .num_readwrite_storage_buffers = num_readwrite_storage_buffers,
        .num_uniform_buffers = num_uniform_buffers,
        .threadcount_x = threadcount_x,
        .threadcount_y = threadcount_y,
        .threadcount_z = threadcount_z,
        .props = 0,
    });
}

fn createComputePipelineEx(
    device: *c.SDL_GPUDevice,
    spv: []const u8,
    msl: []const u8,
    num_readonly_storage_buffers: u32,
    num_readwrite_storage_buffers: u32,
    num_readwrite_storage_textures: u32,
    num_uniform_buffers: u32,
    num_samplers: u32,
    threadcount_x: u32,
    threadcount_y: u32,
    threadcount_z: u32,
) ?*c.SDL_GPUComputePipeline {
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
        std.debug.print("No supported shader format for compute pipeline\n", .{});
        return null;
    }

    return c.SDL_CreateGPUComputePipeline(device, &c.SDL_GPUComputePipelineCreateInfo{
        .code_size = code_size,
        .code = code,
        .entrypoint = entrypoint,
        .format = format,
        .num_samplers = num_samplers,
        .num_readonly_storage_textures = 0,
        .num_readonly_storage_buffers = num_readonly_storage_buffers,
        .num_readwrite_storage_textures = num_readwrite_storage_textures,
        .num_readwrite_storage_buffers = num_readwrite_storage_buffers,
        .num_uniform_buffers = num_uniform_buffers,
        .threadcount_x = threadcount_x,
        .threadcount_y = threadcount_y,
        .threadcount_z = threadcount_z,
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

    const frag_shader = createShader(device, frag_spv, frag_msl, c.SDL_GPU_SHADERSTAGE_FRAGMENT, 3, 6, 3) orelse {
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

    // Two color targets: HDR scene (location 0) + normal+roughness (location 1)
    const color_target_desc = [_]c.SDL_GPUColorTargetDescription{
        .{ .format = scene_format, .blend_state = std.mem.zeroes(c.SDL_GPUColorTargetBlendState) },
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
        self.msaa_normal_texture = createMsaaColorTexture(device, scene_format, config.width, config.height, config.msaa) orelse {
            std.debug.print("Failed to create MSAA normal texture: {s}\n", .{c.SDL_GetError()});
            return error.DepthTextureFailed;
        };
    }
    // Normal+roughness resolve target (same format as HDR, full res, single sample).
    // Created here; also recreated in ensureTextures when resolution changes.
    self.normal_roughness_texture = c.SDL_CreateGPUTexture(device, &c.SDL_GPUTextureCreateInfo{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = scene_format,
        .usage = c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
        .width = config.width,
        .height = config.height,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
        .props = 0,
    }) orelse {
        std.debug.print("Failed to create normal+roughness texture: {s}\n", .{c.SDL_GetError()});
        return error.DepthTextureFailed;
    };
    self.rt_w = config.width;
    self.rt_h = config.height;
}

pub fn initShadowPipeline(self: *Engine) !void {
    const device = self.gpu_device.?;

    const shadow_vs = createShader(device, shadow_vert_spv, shadow_vert_msl, c.SDL_GPU_SHADERSTAGE_VERTEX, 0, 0, 1) orelse return error.ShaderFailed;
    defer c.SDL_ReleaseGPUShader(device, shadow_vs);

    const shadow_fs = createShader(device, shadow_frag_spv, shadow_frag_msl, c.SDL_GPU_SHADERSTAGE_FRAGMENT, 0, 0, 0) orelse return error.ShaderFailed;
    defer c.SDL_ReleaseGPUShader(device, shadow_fs);

    const vertex_attrs = [_]c.SDL_GPUVertexAttribute{
        .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3, .offset = @offsetOf(Vertex, "px") },
        .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3, .offset = @offsetOf(Vertex, "nx") },
        .{ .location = 2, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(Vertex, "u") },
        .{ .location = 3, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4, .offset = @offsetOf(Vertex, "tx") },
    };
    const vertex_buf_desc = [_]c.SDL_GPUVertexBufferDescription{
        .{ .slot = 0, .pitch = @sizeOf(Vertex), .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX, .instance_step_rate = 0 },
    };

    self.shadow_pipeline = c.SDL_CreateGPUGraphicsPipeline(device, &c.SDL_GPUGraphicsPipelineCreateInfo{
        .vertex_shader = shadow_vs,
        .fragment_shader = shadow_fs,
        .vertex_input_state = .{
            .vertex_buffer_descriptions = &vertex_buf_desc,
            .num_vertex_buffers = 1,
            .vertex_attributes = &vertex_attrs,
            .num_vertex_attributes = vertex_attrs.len,
        },
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .rasterizer_state = .{
            .fill_mode = c.SDL_GPU_FILLMODE_FILL,
            .cull_mode = c.SDL_GPU_CULLMODE_NONE,
            .front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE,
            .depth_bias_constant_factor = 4.0,
            .depth_bias_clamp = 0.0,
            .depth_bias_slope_factor = 2.0,
            .enable_depth_bias = true,
            .enable_depth_clip = true,
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
            .color_target_descriptions = &[_]c.SDL_GPUColorTargetDescription{
                .{ .format = c.SDL_GPU_TEXTUREFORMAT_R32_FLOAT, .blend_state = std.mem.zeroes(c.SDL_GPUColorTargetBlendState) },
            },
            .num_color_targets = 1,
            .depth_stencil_format = c.SDL_GPU_TEXTUREFORMAT_D32_FLOAT,
            .has_depth_stencil_target = true,
            .padding1 = 0,
            .padding2 = 0,
            .padding3 = 0,
        },
        .props = 0,
    }) orelse return error.ShadowPipelineFailed;
}

/// Create the GPU compute pipeline for instance data setup.
/// This pipeline replaces the CPU-side uploadInstances() — the compute shader
/// reads raw entity transforms and produces the InstanceData buffer that the
/// vertex shader consumes.
pub fn initComputePipeline(self: *Engine) !void {
    const device = self.gpu_device.?;

    // instance_setup.comp: 2 readonly storage buffers (entity data + batch info),
    // 3 readwrite storage buffers (instance output + indirect commands + culling stats),
    // 1 uniform buffer (VP + frustum planes + counts + HiZ params),
    // 1 sampler (HiZ depth pyramid for occlusion culling).
    // Workgroup size: 64×1×1 (matches local_size_x in the shader).
    self.compute_pipeline = createComputePipeline(
        device,
        instance_setup_spv,
        instance_setup_msl,
        2, // readonly storage buffers (entity data, batch info)
        3, // readwrite storage buffers (instance output, indirect commands, culling stats)
        1, // uniform buffers (VP matrix + frustum + HiZ params)
        1, // samplers (HiZ depth pyramid)
        64,
        1,
        1,
    ) orelse {
        std.debug.print("Failed to create compute pipeline: {s}\n", .{c.SDL_GetError()});
        return error.ComputePipelineFailed;
    };

    // Fog injection compute pipeline: 1 readonly storage buffer (lights),
    // 0 readwrite storage buffers, 1 readwrite storage TEXTURE (froxel image),
    // 1 uniform, 2 samplers (shadow atlas + scene depth). Workgroup: 8x8x1.
    self.fog_inject_pipeline = createComputePipelineEx(
        device,
        fog_inject_spv,
        fog_inject_msl,
        1, // readonly storage buffers (light buffer)
        0, // readwrite storage buffers
        1, // readwrite storage textures (froxel image)
        1, // uniform buffers
        2, // samplers (shadow atlas + scene depth for screen-space shadows)
        8, 8, 1,
    ) orelse {
        std.debug.print("Failed to create fog inject pipeline: {s}\n", .{c.SDL_GetError()});
        return error.ComputePipelineFailed;
    };

    // Culling stats buffer: 3 u32 atomic counters written by compute, read back by CPU.
    self.culling_stats_buffer = c.SDL_CreateGPUBuffer(device, &c.SDL_GPUBufferCreateInfo{
        .usage = c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE,
        .size = @sizeOf(CullingStats),
        .props = 0,
    }) orelse {
        std.debug.print("Failed to create culling stats buffer: {s}\n", .{c.SDL_GetError()});
        return error.BufferFailed;
    };

    // Transfer buffer for async readback (CPU reads previous frame's stats)
    self.culling_stats_transfer = c.SDL_CreateGPUTransferBuffer(device, &c.SDL_GPUTransferBufferCreateInfo{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD,
        .size = @sizeOf(CullingStats),
        .props = 0,
    }) orelse {
        std.debug.print("Failed to create culling stats transfer: {s}\n", .{c.SDL_GetError()});
        return error.BufferFailed;
    };
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

/// Directional light data gathered from ECS.
pub const DirLightData = struct {
    dir: [4]f32,
    color: [4]f32,
};

/// Query the ECS for the first directional light, or return defaults.
/// Uses the persistent dir_light_query + columnar access.
pub fn gatherDirectionalLightPublic(self: *Engine) DirLightData {
    return gatherDirectionalLight(self);
}

fn gatherDirectionalLight(self: *Engine) DirLightData {
    var result = DirLightData{
        .dir = .{ 0.4, 0.8, 0.4, 0.0 },
        .color = .{ 1.0, 1.0, 1.0, 0.0 },
    };
    const q = self.dir_light_query orelse return result;
    var it = ecs.query_iter(self.world, q);

    if (ecs.query_next(&it)) {
        const dls = ecs.field(&it, DirectionalLight, 0) orelse return result;
        if (dls.len > 0) {
            const dl = dls[0];
            const len_sq = dl.dir_x * dl.dir_x + dl.dir_y * dl.dir_y + dl.dir_z * dl.dir_z;
            if (len_sq > 1e-8) {
                result.dir = .{ dl.dir_x, dl.dir_y, dl.dir_z, 0.0 };
            }
            result.color = .{ dl.r, dl.g, dl.b, 0.0 };
        }
    }
    return result;
}

/// Gather all point and spot lights using persistent queries + columnar access.
fn gatherClusterLights(self: *Engine) u32 {
    var count: u32 = 0;

    // Point lights
    if (self.point_light_query) |pl_q| {
        var pl_it = ecs.query_iter(self.world, pl_q);
        while (ecs.query_next(&pl_it)) {
            const positions = ecs.field(&pl_it, Position, 0) orelse continue;
            const lights = ecs.field(&pl_it, PointLight, 1) orelse continue;
            for (0..pl_it.count()) |row| {
                if (count >= max_lights) break;
                const pos = positions[row];
                const pl = lights[row];
                self.cluster_lights[count] = .{
                    .pos_radius = .{ pos.x, pos.y, pos.z, pl.radius },
                    .color_type = .{ pl.r * pl.intensity, pl.g * pl.intensity, pl.b * pl.intensity, 0.0 },
                    .dir_spot = .{ 0, 0, 0, 0 },
                    .cone_params = .{ 0, 0, 0, 0 },
                };
                count += 1;
            }
        }
    }

    // Spot lights
    if (self.spot_light_query) |sl_q| {
        var sl_it = ecs.query_iter(self.world, sl_q);
        while (ecs.query_next(&sl_it)) {
            const positions = ecs.field(&sl_it, Position, 0) orelse continue;
            const lights = ecs.field(&sl_it, SpotLight, 1) orelse continue;
            for (0..sl_it.count()) |row| {
                if (count >= max_lights) break;
                const pos = positions[row];
                const sl = lights[row];
                const inner_rad = sl.inner_cone * (std.math.pi / 180.0);
                const outer_rad = sl.outer_cone * (std.math.pi / 180.0);
                const len_sq = sl.dir_x * sl.dir_x + sl.dir_y * sl.dir_y + sl.dir_z * sl.dir_z;
                const inv_len = if (len_sq > 1e-8) 1.0 / @sqrt(len_sq) else 1.0;
                self.cluster_lights[count] = .{
                    .pos_radius = .{ pos.x, pos.y, pos.z, sl.radius },
                    .color_type = .{ sl.r * sl.intensity, sl.g * sl.intensity, sl.b * sl.intensity, 1.0 },
                    .dir_spot = .{ sl.dir_x * inv_len, sl.dir_y * inv_len, sl.dir_z * inv_len, 0 },
                    .cone_params = .{ @cos(inner_rad), @cos(outer_rad), 0, 0 },
                };
                count += 1;
            }
        }
    }

    self.cluster_light_count = count;
    return count;
}

/// Collect all renderable entities into the draw list, sorted by mesh+material.
fn buildDrawList(self: *Engine) u32 {
    var draw_count: u32 = 0;
    var desc = std.mem.zeroes(ecs.query_desc_t);
    desc.terms[0].id = ecs.id(Position);
    desc.terms[1].id = ecs.id(Rotation);
    desc.terms[2].id = ecs.id(MeshHandle);
    desc.terms[3].id = ecs.id(MaterialHandle);
    desc.terms[3].oper = .Optional;

    const q = ecs.query_init(self.world, &desc) catch return 0;
    defer ecs.query_fini(q);
    var it = ecs.query_iter(self.world, q);

    while (ecs.query_next(&it)) {
        // Column access: one pointer per component per archetype table
        const meshes = ecs.field(&it, MeshHandle, 2) orelse continue;
        const mats = ecs.field(&it, MaterialHandle, 3); // optional — may be null

        for (0..it.count()) |row| {
            if (draw_count >= max_renderables) break;
            const mesh_id: u64 = meshes[row].id;
            const mat_id: u64 = if (mats) |m| m[row].id else 0;
            self.draw_list[draw_count] = .{
                .sort_key = (mesh_id << 32) | mat_id,
                .entity = it.entities()[row],
            };
            draw_count += 1;
        }
    }

    std.mem.sort(DrawEntry, self.draw_list[0..draw_count], {}, struct {
        fn lessThan(_: void, a: DrawEntry, b: DrawEntry) bool {
            return a.sort_key < b.sort_key;
        }
    }.lessThan);

    return draw_count;
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
        const pos = ecs.get(self.world, entry.entity, Position) orelse continue;
        const rot = ecs.get(self.world, entry.entity, Rotation) orelse continue;
        const rotation = Mat4.mul(Mat4.mul(Mat4.rotateZ(rot.z), Mat4.rotateY(rot.y)), Mat4.rotateX(rot.x));
        const scl = if (ecs.get(self.world, entry.entity, Scale)) |s|
            Mat4.scale(s.x, s.y, s.z)
        else
            Mat4.identity();
        const model = Mat4.mul(Mat4.translate(pos.x, pos.y, pos.z), Mat4.mul(rotation, scl));
        const mvp = Mat4.mul(vp, model);
        const receives = if (ecs.has_id(self.world, entry.entity, ecs.id(ShadowReceiver))) @as(f32, 1.0) else @as(f32, 0.0);
        const s = if (ecs.get(self.world, entry.entity, Scale)) |sv| [3]f32{ sv.x, sv.y, sv.z } else [3]f32{ 1, 1, 1 };
        instances[i] = .{ .mvp = mvp.m, .model = model.m, .flags = .{ receives, 1.0 / (s[0] * s[0]), 1.0 / (s[1] * s[1]), 1.0 / (s[2] * s[2]) } };
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

// ============================================================
// GPU-driven instance setup (compute shader path)
// ============================================================

/// Build the full draw list with entity data in a single pass. Gathers
/// transform data using columnar ECS access (cache-coherent), then sorts
/// the draw list and entity data together by mesh+material.
///
/// This replaces the previous three-function sequence (buildDrawList +
/// computeBatches + uploadEntityData) which did per-entity ecs.get on the
/// sorted list — destroying cache coherence and doing 6+ hash lookups per entity.
/// Create the persistent renderable query (called once at init).
/// Queries for entities with Position + Rotation + MeshHandle, with optional
/// Scale, MaterialHandle, ShadowReceiver, ShadowCaster.
pub fn createRenderableQuery(world: *ecs.world_t) ?*ecs.query_t {
    var desc = std.mem.zeroes(ecs.query_desc_t);
    desc.terms[0].id = ecs.id(Position);
    desc.terms[1].id = ecs.id(Rotation);
    desc.terms[2].id = ecs.id(MeshHandle);
    desc.terms[3].id = ecs.id(Scale);
    desc.terms[3].oper = .Optional;
    desc.terms[4].id = ecs.id(MaterialHandle);
    desc.terms[4].oper = .Optional;
    desc.terms[5].id = ecs.id(ShadowReceiver);
    desc.terms[5].oper = .Optional;
    desc.terms[5].inout = .InOutNone;
    desc.terms[6].id = ecs.id(ShadowCaster);
    desc.terms[6].oper = .Optional;
    desc.terms[6].inout = .InOutNone;
    return ecs.query_init(world, &desc) catch null;
}

pub fn prepareDrawData(self: *Engine, cmd: *c.SDL_GPUCommandBuffer) u32 {
    const q = self.renderable_query orelse return 0;

    // --- Pass 1: count entities per sort_key bucket ---
    // Lightweight: only reads MeshHandle + optional MaterialHandle columns.
    var unique_keys: [max_batches]u64 = undefined;
    var key_counts: [max_batches]u32 = .{0} ** max_batches;
    var num_keys: u32 = 0;
    var total_count: u32 = 0;

    {
        var it = ecs.query_iter(self.world, q);
        while (ecs.query_next(&it)) {
            const meshes = ecs.field(&it, MeshHandle, 2) orelse continue;
            const mats = ecs.field(&it, MaterialHandle, 4);
            for (0..it.count()) |row| {
                if (total_count >= max_renderables) break;
                const sk: u64 = (@as(u64, meshes[row].id) << 32) | (if (mats) |m| @as(u64, m[row].id) else 0);
                var found = false;
                for (unique_keys[0..num_keys], 0..) |k, ki| {
                    if (k == sk) {
                        key_counts[ki] += 1;
                        found = true;
                        break;
                    }
                }
                if (!found and num_keys < max_batches) {
                    unique_keys[num_keys] = sk;
                    key_counts[num_keys] = 1;
                    num_keys += 1;
                }
                total_count += 1;
            }
        }
    }

    if (total_count == 0) {
        self.batch_count = 0;
        return 0;
    }

    // Sort unique keys (tiny array, typically <10 elements) + compute offsets
    const KeyCount = struct { key: u64, count: u32 };
    var key_sorted: [max_batches]KeyCount = undefined;
    for (0..num_keys) |i| key_sorted[i] = .{ .key = unique_keys[i], .count = key_counts[i] };
    std.mem.sort(KeyCount, key_sorted[0..num_keys], {}, struct {
        fn lessThan(_: void, a: KeyCount, b: KeyCount) bool {
            return a.key < b.key;
        }
    }.lessThan);

    var bucket_offsets: [max_batches]u32 = undefined;
    var cumulative: u32 = 0;
    for (0..num_keys) |i| {
        bucket_offsets[i] = cumulative;
        self.batch_descriptors[i] = .{
            .mesh_id = @truncate(key_sorted[i].key >> 32),
            .material_id = @truncate(key_sorted[i].key),
            .entity_start = cumulative,
            .entity_count = key_sorted[i].count,
            .instance_offset = cumulative,
        };
        cumulative += key_sorted[i].count;
    }
    self.batch_count = num_keys;

    // --- Pass 2: gather + scatter directly to sorted positions ---
    // No intermediate arrays. Entity data and draw entries are written directly
    // to their final sorted positions using the bucket offsets.
    var scatter_pos: [max_batches]u32 = undefined;
    @memcpy(scatter_pos[0..num_keys], bucket_offsets[0..num_keys]);

    const transfer = self.entity_data_transfer orelse return 0;
    const ptr = c.SDL_MapGPUTransferBuffer(self.gpu_device.?, transfer, true) orelse return 0;
    const entity_data: [*]EntityData = @ptrCast(@alignCast(ptr));

    var draw_count: u32 = 0;
    {
        var it = ecs.query_iter(self.world, q);
        while (ecs.query_next(&it)) {
            const positions = ecs.field(&it, Position, 0) orelse continue;
            const rotations = ecs.field(&it, Rotation, 1) orelse continue;
            const meshes = ecs.field(&it, MeshHandle, 2) orelse continue;
            const scales = ecs.field(&it, Scale, 3);
            const mats = ecs.field(&it, MaterialHandle, 4);
            const has_receiver = ecs.field_is_set(&it, 5);
            const has_caster = ecs.field_is_set(&it, 6);

            const receives_f: f32 = if (has_receiver) 1.0 else 0.0;
            const caster_f: f32 = if (has_caster) 1.0 else 0.0;

            for (0..it.count()) |row| {
                if (draw_count >= max_renderables) break;
                const pos = positions[row];
                const rot = rotations[row];
                const mesh_id: u64 = meshes[row].id;
                const mat_id: u64 = if (mats) |m| m[row].id else 0;
                const sk: u64 = (mesh_id << 32) | mat_id;

                // Find bucket and get the sorted output position
                var bucket: u32 = 0;
                for (0..num_keys) |ki| {
                    if (key_sorted[ki].key == sk) {
                        bucket = @intCast(ki);
                        break;
                    }
                }
                const dst = scatter_pos[bucket];
                scatter_pos[bucket] += 1;

                self.draw_list[dst] = .{
                    .sort_key = sk,
                    .entity = it.entities()[row],
                };
                entity_data[dst] = .{
                    .position = .{ pos.x, pos.y, pos.z, receives_f },
                    .rotation = .{ rot.x, rot.y, rot.z, @floatFromInt(bucket) },
                    .scale_flags = if (scales) |s| .{ s[row].x, s[row].y, s[row].z, caster_f } else .{ 1, 1, 1, caster_f },
                };
                draw_count += 1;
            }
        }
    }

    // --- Write batch info + indirect commands + zeroed culling stats into the SAME transfer buffer ---
    // This avoids multiple map/unmap cycles. Layout: [entity data | batch info | indirect cmds | culling stats]
    const entity_data_bytes: u32 = draw_count * @sizeOf(EntityData);
    const batch_region_offset: u32 = entity_data_bytes;
    const batch_info_size: u32 = self.batch_count * @sizeOf(BatchInfo);
    const indirect_size: u32 = self.batch_count * @sizeOf(IndirectDrawCommand);
    const stats_size: u32 = @sizeOf(CullingStats);

    const batch_base: [*]u8 = @as([*]u8, @ptrCast(entity_data)) + entity_data_bytes;
    const batch_infos: [*]BatchInfo = @ptrCast(@alignCast(batch_base));
    const indirect_base: [*]u8 = batch_base + batch_info_size;
    const indirect_cmds: [*]IndirectDrawCommand = @ptrCast(@alignCast(indirect_base));
    // Zero the culling stats (3 u32 counters) so compute shader atomicAdds start from 0
    const stats_base: [*]u8 = indirect_base + indirect_size;
    const stats_ptr: *CullingStats = @ptrCast(@alignCast(stats_base));
    stats_ptr.* = .{};

    for (self.batch_descriptors[0..self.batch_count], 0..) |batch, i| {
        batch_infos[i] = .{ .instance_offset = batch.instance_offset };
        const mesh = self.assets.mesh_registry[batch.mesh_id] orelse continue;
        indirect_cmds[i] = .{
            .num_indices = mesh.index_count,
            .num_instances = 0,
            .first_index = mesh.first_index,
            .vertex_offset = @intCast(mesh.base_vertex),
            .first_instance = batch.instance_offset,
        };
    }

    // Single unmap + single copy pass for all three uploads
    c.SDL_UnmapGPUTransferBuffer(self.gpu_device.?, transfer);

    const gpu_buf = self.entity_data_buffer orelse return draw_count;
    const batch_info_buf = self.batch_info_buffer orelse return draw_count;
    const indirect_buf = self.indirect_draw_buffer orelse return draw_count;
    const stats_buf = self.culling_stats_buffer orelse return draw_count;

    const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse return draw_count;

    // Entity data
    c.SDL_UploadToGPUBuffer(copy_pass, &c.SDL_GPUTransferBufferLocation{
        .transfer_buffer = transfer,
        .offset = 0,
    }, &c.SDL_GPUBufferRegion{
        .buffer = gpu_buf,
        .offset = 0,
        .size = entity_data_bytes,
    }, true);

    // Batch info
    c.SDL_UploadToGPUBuffer(copy_pass, &c.SDL_GPUTransferBufferLocation{
        .transfer_buffer = transfer,
        .offset = batch_region_offset,
    }, &c.SDL_GPUBufferRegion{
        .buffer = batch_info_buf,
        .offset = 0,
        .size = batch_info_size,
    }, true);

    // Indirect draw commands
    c.SDL_UploadToGPUBuffer(copy_pass, &c.SDL_GPUTransferBufferLocation{
        .transfer_buffer = transfer,
        .offset = batch_region_offset + batch_info_size,
    }, &c.SDL_GPUBufferRegion{
        .buffer = indirect_buf,
        .offset = 0,
        .size = indirect_size,
    }, true);

    // Zeroed culling stats (so compute shader atomicAdds start fresh)
    c.SDL_UploadToGPUBuffer(copy_pass, &c.SDL_GPUTransferBufferLocation{
        .transfer_buffer = transfer,
        .offset = batch_region_offset + batch_info_size + indirect_size,
    }, &c.SDL_GPUBufferRegion{
        .buffer = stats_buf,
        .offset = 0,
        .size = stats_size,
    }, true);

    c.SDL_EndGPUCopyPass(copy_pass);

    return draw_count;
}

/// Dispatch the instance setup compute shader. Reads entity data from the GPU
/// entity_data_buffer and writes InstanceData to instance_buffer using the
/// provided VP matrix. Call this instead of uploadInstances() when using the
/// compute pipeline.
///
/// The shadow_pass flag controls behavior for non-shadow-caster entities:
/// in shadow mode, they get zeroed MVPs (degenerate triangles = no fragments).
pub fn dispatchInstanceSetup(self: *Engine, cmd: *c.SDL_GPUCommandBuffer, vp: Mat4, draw_count: u32, shadow_pass: bool, frustum_cull: bool, occlusion_cull: bool) void {
    if (draw_count == 0) return;
    const pipeline = self.compute_pipeline orelse return;
    const instance_buf = self.instance_buffer orelse return;
    const entity_buf = self.entity_data_buffer orelse return;
    const batch_info_buf = self.batch_info_buffer orelse return;
    const indirect_buf = self.indirect_draw_buffer orelse return;
    const stats_buf = self.culling_stats_buffer orelse return;

    // Resolve HiZ combined mipmapped texture for occlusion culling.
    // If HiZ isn't available (first frame, or textures not yet created), disable occlusion.
    const pp = &self.postprocess;
    const hiz_tex = pp.hiz_combined;
    const hiz_sampler = pp.hiz_sampler;
    const do_occlusion = occlusion_cull and !shadow_pass and hiz_tex != null and hiz_sampler != null;

    // Begin compute pass — readwrite outputs: instance buffer + culling stats + indirect commands.
    // IMPORTANT: The order must match the GLSL shader's first-access order for each buffer,
    // because spirv-cross assigns MSL [[buffer(N)]] indices by first access. The shader
    // accesses instances first, then culling_stats (atomicAdd in culling branches), then
    // indirect_commands (atomicAdd for visible entities). SDL3 maps rw_bindings[i] to the
    // i-th readwrite buffer index.
    //
    // Instance buffer cycles (new version each frame, previous frame may still read it).
    // Indirect buffer does NOT cycle — we just uploaded num_instances=0 via copy pass
    // and need the compute shader to atomicAdd to that same version.
    // Stats buffer cycles on scene pass (fresh counters each frame).
    const zero_pad = [3]u8{ 0, 0, 0 };
    const rw_bindings = [3]c.SDL_GPUStorageBufferReadWriteBinding{
        .{ .buffer = instance_buf, .cycle = true, .padding1 = zero_pad[0], .padding2 = zero_pad[1], .padding3 = zero_pad[2] },
        .{ .buffer = stats_buf, .cycle = false, .padding1 = zero_pad[0], .padding2 = zero_pad[1], .padding3 = zero_pad[2] },
        .{ .buffer = indirect_buf, .cycle = false, .padding1 = zero_pad[0], .padding2 = zero_pad[1], .padding3 = zero_pad[2] },
    };
    const compute_pass = c.SDL_BeginGPUComputePass(cmd, null, 0, &rw_bindings, 3) orelse return;

    c.SDL_BindGPUComputePipeline(compute_pass, pipeline);

    // Bind readonly storage buffers: entity data (slot 0) + batch info (slot 1)
    const ro_bufs = [2]*c.SDL_GPUBuffer{ entity_buf, batch_info_buf };
    c.SDL_BindGPUComputeStorageBuffers(compute_pass, 0, &ro_bufs, 2);

    // Bind HiZ sampler (even when not culling — shader checks occlusion_cull flag).
    // We always bind a valid texture to avoid GPU errors; when occlusion is off,
    // the shader never samples it.
    if (hiz_tex) |tex| {
        if (hiz_sampler) |samp| {
            const tex_sampler = c.SDL_GPUTextureSamplerBinding{
                .texture = tex,
                .sampler = samp,
            };
            c.SDL_BindGPUComputeSamplers(compute_pass, 0, &tex_sampler, 1);
        }
    }

    // Push uniforms: VP matrix, frustum planes, entity count, modes, HiZ params
    const hiz_w: f32 = if (pp.hiz_count > 0) @floatFromInt(pp.hiz_widths[0]) else 0;
    const hiz_h: f32 = if (pp.hiz_count > 0) @floatFromInt(pp.hiz_heights[0]) else 0;
    const max_mip: f32 = if (pp.hiz_count > 1) @as(f32, @floatFromInt(pp.hiz_count - 1)) else 0;

    const uniforms = ComputeUniforms{
        .vp = vp.m,
        .frustum_planes = if (frustum_cull) extractFrustumPlanes(vp) else std.mem.zeroes([6][4]f32),
        .entity_count = draw_count,
        .shadow_pass = if (shadow_pass) 1 else 0,
        .frustum_cull = if (frustum_cull) 1 else 0,
        .occlusion_cull = if (do_occlusion) 1 else 0,
        .prev_vp = self.prev_vp,
        .prev_camera_pos = self.prev_camera_pos,
        .hiz_params = .{ hiz_w, hiz_h, max_mip, 0 },
    };
    c.SDL_PushGPUComputeUniformData(cmd, 0, &uniforms, @sizeOf(ComputeUniforms));

    // Dispatch: one thread per entity, 64 threads per workgroup
    const workgroups = (draw_count + 63) / 64;
    c.SDL_DispatchGPUCompute(compute_pass, workgroups, 1, 1);

    c.SDL_EndGPUComputePass(compute_pass);
}

/// Compute per-instance matrices via GPU compute dispatch. Replaces the CPU-side
/// uploadInstanceData that used transfer buffer uploads.
pub fn dispatchInstanceData(self: *Engine, cmd: *c.SDL_GPUCommandBuffer, cam_entity: ecs.entity_t, w: u32, h: u32, frame: FrameContext) void {
    const vp = computeVP(self, cam_entity, w, h);
    // Scene pass: frustum cull + HiZ occlusion cull (if HiZ data available)
    dispatchInstanceSetup(self, cmd, vp, frame.draw_count, false, true, true);

    // Store current VP and camera position for next frame's HiZ reprojection
    self.prev_vp = vp.m;
    if (ecs.get(self.world, cam_entity, Position)) |pos| {
        self.prev_camera_pos = .{ pos.x, pos.y, pos.z, 0 };
    }

    // Schedule async readback of culling stats (GPU → transfer buffer).
    // The CPU reads the transfer buffer at the start of the NEXT frame (no stall).
    downloadCullingStats(self, cmd);
}

/// Download culling stats from GPU to transfer buffer for async readback.
fn downloadCullingStats(self: *Engine, cmd: *c.SDL_GPUCommandBuffer) void {
    const gpu_buf = self.culling_stats_buffer orelse return;
    const transfer = self.culling_stats_transfer orelse return;

    const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse return;
    c.SDL_DownloadFromGPUBuffer(
        copy_pass,
        &c.SDL_GPUBufferRegion{
            .buffer = gpu_buf,
            .offset = 0,
            .size = @sizeOf(CullingStats),
        },
        &c.SDL_GPUTransferBufferLocation{
            .transfer_buffer = transfer,
            .offset = 0,
        },
    );
    c.SDL_EndGPUCopyPass(copy_pass);
}

/// Read the previous frame's culling stats from the transfer buffer.
/// Call at the start of each frame, before the compute dispatch overwrites the GPU buffer.
pub fn readbackCullingStats(self: *Engine) void {
    const transfer = self.culling_stats_transfer orelse return;
    const ptr = c.SDL_MapGPUTransferBuffer(self.gpu_device.?, transfer, false) orelse return;
    const stats: *const CullingStats = @ptrCast(@alignCast(ptr));
    self.culling_stats = stats.*;
    c.SDL_UnmapGPUTransferBuffer(self.gpu_device.?, transfer);
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

    // Bind instance storage buffer (per-instance transforms from compute shader)
    const buf_ptr = [1]*c.SDL_GPUBuffer{self.instance_buffer.?};
    c.SDL_BindGPUVertexStorageBuffers(render_pass, 0, &buf_ptr, 1);

    // Bind merged geometry buffers once for the entire pass — no per-batch rebinding.
    // Each batch uses base_vertex/first_index offsets in the draw call instead.
    const vb_binding = c.SDL_GPUBufferBinding{ .buffer = self.merged_vertex_buffer.?, .offset = 0 };
    c.SDL_BindGPUVertexBuffers(render_pass, 0, &vb_binding, 1);
    c.SDL_BindGPUIndexBuffer(render_pass, &c.SDL_GPUBufferBinding{ .buffer = self.merged_index_buffer.?, .offset = 0 }, c.SDL_GPU_INDEXELEMENTSIZE_32BIT);

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

        // Instanced draw — use merged buffer offsets (base_vertex, first_index)
        if (mesh.indexed) {
            c.SDL_DrawGPUIndexedPrimitives(render_pass, mesh.index_count, instance_count, mesh.first_index, @intCast(mesh.base_vertex), batch_start);
        } else {
            c.SDL_DrawGPUPrimitives(render_pass, mesh.vertex_count, instance_count, mesh.base_vertex, batch_start);
        }

        batch_start = batch_end;
    }
}

/// Submit draw calls using GPU-driven indirect rendering. The compute shader
/// has already compacted visible instances and written indirect draw commands
/// (with num_instances set via atomicAdd). The CPU just iterates batches,
/// binds material state, and issues one indirect draw per batch.
pub fn submitDrawCallsIndirect(
    self: *Engine,
    cmd: *c.SDL_GPUCommandBuffer,
    render_pass: *c.SDL_GPURenderPass,
) void {
    if (self.batch_count == 0) return;
    const indirect_buf = self.indirect_draw_buffer orelse return;
    const default_material = MaterialUniforms{ .albedo = .{ 1, 1, 1, 1 } };

    // Bind instance storage buffer (per-instance transforms from compute shader)
    const buf_ptr = [1]*c.SDL_GPUBuffer{self.instance_buffer.?};
    c.SDL_BindGPUVertexStorageBuffers(render_pass, 0, &buf_ptr, 1);

    // Bind merged geometry buffers once
    const vb_binding = c.SDL_GPUBufferBinding{ .buffer = self.merged_vertex_buffer.?, .offset = 0 };
    c.SDL_BindGPUVertexBuffers(render_pass, 0, &vb_binding, 1);
    c.SDL_BindGPUIndexBuffer(render_pass, &c.SDL_GPUBufferBinding{ .buffer = self.merged_index_buffer.?, .offset = 0 }, c.SDL_GPU_INDEXELEMENTSIZE_32BIT);

    const sampler = self.assets.default_sampler.?;
    const dummy = self.assets.dummy_texture.?;

    for (self.batch_descriptors[0..self.batch_count], 0..) |batch, i| {
        // Bind material
        if (self.assets.material_registry[batch.material_id]) |mat| {
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

        // Indirect draw — GPU determines instance count from the compute shader's atomicAdd
        const cmd_offset: u32 = @intCast(i * @sizeOf(IndirectDrawCommand));
        c.SDL_DrawGPUIndexedPrimitivesIndirect(render_pass, indirect_buf, cmd_offset, 1);
    }
}

/// Cached per-frame scene data (computed once, shared across cameras).
pub const FrameContext = struct {
    dir_light: DirLightData,
    draw_count: u32,
    light_count: u32,
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
            if (self.msaa_normal_texture) |mt| c.SDL_ReleaseGPUTexture(device, mt);
            self.msaa_normal_texture = createMsaaColorTexture(device, hdr_format, w, h, self.sample_count);
        }
        if (self.normal_roughness_texture) |t| c.SDL_ReleaseGPUTexture(device, t);
        self.normal_roughness_texture = c.SDL_CreateGPUTexture(device, &c.SDL_GPUTextureCreateInfo{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = hdr_format,
            .usage = c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = w,
            .height = h,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
            .props = 0,
        });
        self.rt_w = w;
        self.rt_h = h;
    }

    return .{
        .dir_light = gatherDirectionalLight(self),
        .draw_count = 0, // actual draw count set by prepareDrawData
        .light_count = gatherClusterLights(self),
    };
}

/// Compute the view matrix for a camera entity.
fn computeView(self: *Engine, cam_entity: ecs.entity_t) Mat4 {
    const cam_pos = ecs.get(self.world, cam_entity, Position) orelse
        return Mat4.viewFromTransform(0, 0, 0, 0, 0, 0);
    const eye = Vec3.new(cam_pos.x, cam_pos.y, cam_pos.z);
    return if (ecs.get(self.world, cam_entity, LookAt)) |look_at| blk: {
        const target_entity: ecs.entity_t = @intCast(look_at.target);
        if (ecs.is_alive(self.world, target_entity)) {
            if (ecs.get(self.world, target_entity, Position)) |target_pos| {
                break :blk Mat4.lookAt(eye, Vec3.new(target_pos.x, target_pos.y, target_pos.z), Vec3.new(0, 1, 0));
            }
        }
        break :blk Mat4.viewFromTransform(cam_pos.x, cam_pos.y, cam_pos.z, 0, 0, 0);
    } else if (ecs.get(self.world, cam_entity, Rotation)) |cam_rot| blk: {
        break :blk Mat4.viewFromTransform(cam_pos.x, cam_pos.y, cam_pos.z, cam_rot.x, cam_rot.y, cam_rot.z);
    } else Mat4.viewFromTransform(cam_pos.x, cam_pos.y, cam_pos.z, 0, 0, 0);
}

/// Compute the view-projection matrix for a camera entity.
/// Compute the view-projection matrix for a camera entity. Public for use by
/// the post-process pipeline (SSR needs VP and inverse VP for world reconstruction).
pub fn computeVPPublic(self: *Engine, cam_entity: ecs.entity_t, w: u32, h: u32) Mat4 {
    return computeVP(self, cam_entity, w, h);
}

fn computeVP(self: *Engine, cam_entity: ecs.entity_t, w: u32, h: u32) Mat4 {
    const cam = ecs.get(self.world, cam_entity, Camera) orelse return Mat4.identity();
    const w_f: f32 = @floatFromInt(w);
    const h_f: f32 = @floatFromInt(h);
    const vp_w = cam.viewport_w * w_f;
    const vp_h = cam.viewport_h * h_f;
    const aspect: f32 = vp_w / vp_h;
    const proj = Mat4.perspective(cam.fov, aspect, cam.near, cam.far);
    const view = computeView(self, cam_entity);
    return Mat4.mul(proj, view);
}

// ============================================================
// Clustered lighting: assignment and upload
// ============================================================

/// Assign lights to clusters using a two-pass count-then-fill algorithm.
/// Conservative: assigns each light to all XY tiles within its Z slice range.
fn assignLightsToClusters(self: *Engine, cam_pos_world: [3]f32, near: f32, far: f32) void {
    const light_count = self.cluster_light_count;
    const log_ratio = @log(far / near);
    const cz_f: f32 = @floatFromInt(cluster_z);

    // Reset cluster infos
    for (0..num_clusters) |i| {
        self.cluster_infos[i] = .{ .offset = 0, .count = 0 };
    }

    if (light_count == 0) {
        self.cluster_index_count = 0;
        return;
    }

    // Pass 1: Count lights per cluster
    for (0..light_count) |li| {
        const light = self.cluster_lights[li];
        const radius = light.pos_radius[3];
        const wx = light.pos_radius[0];
        const wy = light.pos_radius[1];
        const wz = light.pos_radius[2];

        // Radial distance from camera (matches shader's length(world_pos - camera_pos))
        const dx = wx - cam_pos_world[0];
        const dy = wy - cam_pos_world[1];
        const dz = wz - cam_pos_world[2];
        const dist = @sqrt(dx * dx + dy * dy + dz * dz);

        // Frustum cull: light sphere vs near/far
        if (dist + radius < near or dist - radius > far) continue;

        // Z slice range (exponential)
        const z_min_depth = @max(dist - radius, near);
        const z_max_depth = @min(dist + radius, far);
        const z_min_f = @max(@floor(@log(z_min_depth / near) / log_ratio * cz_f), 0);
        const z_max_f = @min(@ceil(@log(z_max_depth / near) / log_ratio * cz_f), cz_f - 1);
        const z_min: u32 = @intFromFloat(z_min_f);
        const z_max: u32 = @intFromFloat(z_max_f);

        // Conservative: assign to all XY tiles within Z range
        // TODO: Project light sphere to screen for tighter XY bounds
        var zz: u32 = z_min;
        while (zz <= z_max) : (zz += 1) {
            const z_base = zz * cluster_x * cluster_y;
            var yy: u32 = 0;
            while (yy < cluster_y) : (yy += 1) {
                const zy_base = z_base + yy * cluster_x;
                var xx: u32 = 0;
                while (xx < cluster_x) : (xx += 1) {
                    const idx = zy_base + xx;
                    if (self.cluster_infos[idx].count < 255) {
                        self.cluster_infos[idx].count += 1;
                    }
                }
            }
        }
    }

    // Prefix sum to compute offsets
    var offset: u32 = 0;
    for (0..num_clusters) |i| {
        self.cluster_infos[i].offset = offset;
        offset += self.cluster_infos[i].count;
        self.cluster_infos[i].count = 0; // Reset for fill pass
    }
    self.cluster_index_count = @min(offset, max_light_indices);

    // Pass 2: Fill light indices
    for (0..light_count) |li| {
        const light = self.cluster_lights[li];
        const radius = light.pos_radius[3];
        const wx = light.pos_radius[0];
        const wy = light.pos_radius[1];
        const wz = light.pos_radius[2];

        const dx = wx - cam_pos_world[0];
        const dy = wy - cam_pos_world[1];
        const dz = wz - cam_pos_world[2];
        const dist = @sqrt(dx * dx + dy * dy + dz * dz);

        if (dist + radius < near or dist - radius > far) continue;

        const z_min_depth = @max(dist - radius, near);
        const z_max_depth = @min(dist + radius, far);
        const z_min_f = @max(@floor(@log(z_min_depth / near) / log_ratio * cz_f), 0);
        const z_max_f = @min(@ceil(@log(z_max_depth / near) / log_ratio * cz_f), cz_f - 1);
        const z_min: u32 = @intFromFloat(z_min_f);
        const z_max: u32 = @intFromFloat(z_max_f);

        var zz: u32 = z_min;
        while (zz <= z_max) : (zz += 1) {
            const z_base = zz * cluster_x * cluster_y;
            var yy: u32 = 0;
            while (yy < cluster_y) : (yy += 1) {
                const zy_base = z_base + yy * cluster_x;
                var xx: u32 = 0;
                while (xx < cluster_x) : (xx += 1) {
                    const idx = zy_base + xx;
                    const info = &self.cluster_infos[idx];
                    const write_pos = info.offset + info.count;
                    if (write_pos < max_light_indices and info.count < 255) {
                        self.cluster_indices[write_pos] = @intCast(li);
                        info.count += 1;
                    }
                }
            }
        }
    }
}

/// Upload cluster data (lights, cluster info, light indices) to GPU via a single copy pass.
fn uploadClusterData(self: *Engine, cmd: *c.SDL_GPUCommandBuffer) void {
    const transfer = self.cluster_transfer orelse return;
    const device = self.gpu_device.?;

    const light_size = self.cluster_light_count * @sizeOf(GPULight);
    const info_size = num_clusters * @sizeOf(ClusterInfo);
    const index_size = self.cluster_index_count * @sizeOf(u32);

    // Fixed offsets in transfer buffer (use max sizes for alignment)
    const info_offset: u32 = max_lights * @sizeOf(GPULight);
    const index_offset: u32 = info_offset + num_clusters * @sizeOf(ClusterInfo);

    const ptr = c.SDL_MapGPUTransferBuffer(device, transfer, true) orelse return;
    const bytes: [*]u8 = @ptrCast(ptr);

    if (light_size > 0) {
        const src = std.mem.sliceAsBytes(self.cluster_lights[0..self.cluster_light_count]);
        @memcpy(bytes[0..src.len], src);
    }
    {
        const src = std.mem.sliceAsBytes(&self.cluster_infos);
        @memcpy(bytes[info_offset..][0..src.len], src);
    }
    if (index_size > 0) {
        const src = std.mem.sliceAsBytes(self.cluster_indices[0..self.cluster_index_count]);
        @memcpy(bytes[index_offset..][0..src.len], src);
    }

    c.SDL_UnmapGPUTransferBuffer(device, transfer);

    const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse return;

    // Always upload at least a minimal amount so the buffer is valid
    c.SDL_UploadToGPUBuffer(copy_pass, &c.SDL_GPUTransferBufferLocation{
        .transfer_buffer = transfer,
        .offset = 0,
    }, &c.SDL_GPUBufferRegion{
        .buffer = self.cluster_light_buffer.?,
        .offset = 0,
        .size = @max(light_size, @sizeOf(GPULight)),
    }, true);

    c.SDL_UploadToGPUBuffer(copy_pass, &c.SDL_GPUTransferBufferLocation{
        .transfer_buffer = transfer,
        .offset = info_offset,
    }, &c.SDL_GPUBufferRegion{
        .buffer = self.cluster_info_buffer.?,
        .offset = 0,
        .size = info_size,
    }, true);

    if (index_size > 0) {
        c.SDL_UploadToGPUBuffer(copy_pass, &c.SDL_GPUTransferBufferLocation{
            .transfer_buffer = transfer,
            .offset = index_offset,
        }, &c.SDL_GPUBufferRegion{
            .buffer = self.cluster_index_buffer.?,
            .offset = 0,
            .size = index_size,
        }, true);
    }

    c.SDL_EndGPUCopyPass(copy_pass);
}

/// Assign lights to clusters and upload cluster data for a specific camera.
pub fn updateClusters(self: *Engine, cmd: *c.SDL_GPUCommandBuffer, cam_entity: ecs.entity_t) void {
    const cam = ecs.get(self.world, cam_entity, Camera) orelse return;
    const cam_pos = ecs.get(self.world, cam_entity, Position) orelse return;
    assignLightsToClusters(self, .{ cam_pos.x, cam_pos.y, cam_pos.z }, cam.near, cam.far);
    uploadClusterData(self, cmd);
}

// ============================================================
// Cascaded Shadow Maps: computation and rendering
// ============================================================

fn computeCascadeSplits(near: f32, far: f32) [cascade_count]f32 {
    var splits: [cascade_count]f32 = undefined;
    for (0..cascade_count) |i| {
        const p: f32 = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(cascade_count));
        const log_split = near * std.math.pow(f32, far / near, p);
        const uniform_split = near + (far - near) * p;
        splits[i] = cascade_lambda * log_split + (1.0 - cascade_lambda) * uniform_split;
    }
    return splits;
}

fn frustumCorners(fov_deg: f32, aspect: f32, near: f32, far: f32, view: Mat4) [8]Vec3 {
    const fov_rad = fov_deg * (std.math.pi / 180.0);
    const tan_half = @tan(fov_rad / 2.0);

    const near_h = near * tan_half;
    const near_w = near_h * aspect;
    const far_h = far * tan_half;
    const far_w = far_h * aspect;

    // Corners in view space (camera looks down -Z)
    const vc = [8][3]f32{
        .{ -near_w, near_h, -near },
        .{ near_w, near_h, -near },
        .{ near_w, -near_h, -near },
        .{ -near_w, -near_h, -near },
        .{ -far_w, far_h, -far },
        .{ far_w, far_h, -far },
        .{ far_w, -far_h, -far },
        .{ -far_w, -far_h, -far },
    };

    // Invert the rigid-body view matrix (transpose rotation + negate translation)
    var inv: Mat4 = Mat4.identity();
    for (0..3) |col| {
        for (0..3) |row| {
            inv.m[col][row] = view.m[row][col];
        }
    }
    inv.m[3][0] = -(view.m[3][0] * inv.m[0][0] + view.m[3][1] * inv.m[1][0] + view.m[3][2] * inv.m[2][0]);
    inv.m[3][1] = -(view.m[3][0] * inv.m[0][1] + view.m[3][1] * inv.m[1][1] + view.m[3][2] * inv.m[2][1]);
    inv.m[3][2] = -(view.m[3][0] * inv.m[0][2] + view.m[3][1] * inv.m[1][2] + view.m[3][2] * inv.m[2][2]);

    var result: [8]Vec3 = undefined;
    for (0..8) |i| {
        result[i] = Vec3.new(
            inv.m[0][0] * vc[i][0] + inv.m[1][0] * vc[i][1] + inv.m[2][0] * vc[i][2] + inv.m[3][0],
            inv.m[0][1] * vc[i][0] + inv.m[1][1] * vc[i][1] + inv.m[2][1] * vc[i][2] + inv.m[3][1],
            inv.m[0][2] * vc[i][0] + inv.m[1][2] * vc[i][1] + inv.m[2][2] * vc[i][2] + inv.m[3][2],
        );
    }
    return result;
}

const CascadeData = struct {
    light_vp: [cascade_count]Mat4,
    splits: [cascade_count]f32,
};

fn computeCascades(self: *Engine, cam_entity: ecs.entity_t, w: u32, h: u32, light_dir: [4]f32) CascadeData {
    const cam = ecs.get(self.world, cam_entity, Camera) orelse return std.mem.zeroes(CascadeData);
    const near = cam.near;
    const far = @min(cam.far, 80.0);
    const splits = computeCascadeSplits(near, far);
    const view = computeView(self, cam_entity);

    const w_f: f32 = @floatFromInt(w);
    const h_f: f32 = @floatFromInt(h);
    const aspect = (cam.viewport_w * w_f) / (cam.viewport_h * h_f);

    const ld = Vec3.normalize(Vec3.new(light_dir[0], light_dir[1], light_dir[2]));

    var result: CascadeData = undefined;
    result.splits = splits;

    var prev_split = near;
    for (0..cascade_count) |ci| {
        const cur_split = splits[ci];
        const corners = frustumCorners(cam.fov, aspect, prev_split, cur_split, view);

        // Frustum center
        var center = Vec3.new(0, 0, 0);
        for (corners) |corner| {
            center = Vec3.add(center, corner);
        }
        center = Vec3.scaleVec(center, 1.0 / 8.0);

        // Light view matrix
        const light_view = Mat4.lookAt(
            Vec3.add(center, Vec3.scaleVec(ld, 50.0)),
            center,
            Vec3.new(0, 1, 0),
        );

        // Find AABB of corners in light view space
        var min_x: f32 = std.math.floatMax(f32);
        var min_y: f32 = std.math.floatMax(f32);
        var min_z: f32 = std.math.floatMax(f32);
        var max_x: f32 = -std.math.floatMax(f32);
        var max_y: f32 = -std.math.floatMax(f32);
        var max_z: f32 = -std.math.floatMax(f32);

        for (corners) |corner| {
            const lx = light_view.m[0][0] * corner.x + light_view.m[1][0] * corner.y + light_view.m[2][0] * corner.z + light_view.m[3][0];
            const ly = light_view.m[0][1] * corner.x + light_view.m[1][1] * corner.y + light_view.m[2][1] * corner.z + light_view.m[3][1];
            const lz = light_view.m[0][2] * corner.x + light_view.m[1][2] * corner.y + light_view.m[2][2] * corner.z + light_view.m[3][2];
            min_x = @min(min_x, lx);
            min_y = @min(min_y, ly);
            min_z = @min(min_z, lz);
            max_x = @max(max_x, lx);
            max_y = @max(max_y, ly);
            max_z = @max(max_z, lz);
        }

        // Extend Z to catch shadow casters behind the camera frustum
        min_z -= 100.0;

        // Texel snapping to prevent shadow shimmer on camera movement
        const cascade_size_f: f32 = @floatFromInt(shadow_cascade_size);
        const wu_per_texel_x = (max_x - min_x) / cascade_size_f;
        const wu_per_texel_y = (max_y - min_y) / cascade_size_f;
        if (wu_per_texel_x > 0) {
            min_x = @floor(min_x / wu_per_texel_x) * wu_per_texel_x;
            max_x = @floor(max_x / wu_per_texel_x) * wu_per_texel_x;
        }
        if (wu_per_texel_y > 0) {
            min_y = @floor(min_y / wu_per_texel_y) * wu_per_texel_y;
            max_y = @floor(max_y / wu_per_texel_y) * wu_per_texel_y;
        }

        // Ortho projection: in light view space, looking down -Z,
        // objects are at negative Z. near/far for ortho are positive distances.
        const light_proj = Mat4.ortho(min_x, max_x, min_y, max_y, -max_z, -min_z);
        result.light_vp[ci] = Mat4.mul(light_proj, light_view);
        prev_split = cur_split;
    }

    return result;
}

fn emptyShadowUniforms() ShadowUniforms {
    return ShadowUniforms{
        .light_vp = .{.{.{ 0, 0, 0, 0 }} ** 4} ** cascade_count,
        .cascade_splits = .{ 0, 0, 0, 0 },
        .shadow_params = .{ 0, 0, 0, 0 }, // .w = 0 means disabled
    };
}

fn submitShadowDrawCalls(self: *Engine, render_pass: *c.SDL_GPURenderPass, draw_count: u32) u32 {
    if (draw_count == 0) return 0;
    var batch_count: u32 = 0;

    // Bind merged geometry buffers once for the entire shadow pass
    const vb_binding = c.SDL_GPUBufferBinding{ .buffer = self.merged_vertex_buffer.?, .offset = 0 };
    c.SDL_BindGPUVertexBuffers(render_pass, 0, &vb_binding, 1);
    c.SDL_BindGPUIndexBuffer(render_pass, &c.SDL_GPUBufferBinding{ .buffer = self.merged_index_buffer.?, .offset = 0 }, c.SDL_GPU_INDEXELEMENTSIZE_32BIT);

    var batch_start: u32 = 0;
    while (batch_start < draw_count) {
        const sort_key = self.draw_list[batch_start].sort_key;
        var batch_end: u32 = batch_start + 1;
        while (batch_end < draw_count and self.draw_list[batch_end].sort_key == sort_key) {
            batch_end += 1;
        }
        const instance_count = batch_end - batch_start;
        const mesh_id: u32 = @truncate(sort_key >> 32);
        const mesh = self.assets.mesh_registry[mesh_id] orelse {
            batch_start = batch_end;
            continue;
        };

        if (mesh.indexed) {
            c.SDL_DrawGPUIndexedPrimitives(render_pass, mesh.index_count, instance_count, mesh.first_index, @intCast(mesh.base_vertex), batch_start);
        } else {
            c.SDL_DrawGPUPrimitives(render_pass, mesh.vertex_count, instance_count, mesh.base_vertex, batch_start);
        }

        batch_count += 1;
        batch_start = batch_end;
    }
    return batch_count;
}

/// Render cascaded shadow maps. Uses a separate copy+render pass per cascade
/// because each cascade needs different instance data (light VP * model as MVP).
pub fn executeShadowPass(
    self: *Engine,
    cmd: *c.SDL_GPUCommandBuffer,
    cam_entity: ecs.entity_t,
    w: u32,
    h: u32,
    frame: FrameContext,
) ShadowUniforms {
    const shadow_atlas = self.shadow_atlas orelse return emptyShadowUniforms();
    const shadow_pipe = self.shadow_pipeline orelse return emptyShadowUniforms();
    const shadow_depth_tex = self.shadow_depth orelse return emptyShadowUniforms();
    if (frame.draw_count == 0) return emptyShadowUniforms();

    const gpu_buf = self.instance_buffer orelse return emptyShadowUniforms();

    const cascades = computeCascades(self, cam_entity, w, h, frame.dir_light.dir);

    const offsets_px = [cascade_count][2]f32{
        .{ 0, 0 },
        .{ 2048, 0 },
        .{ 0, 2048 },
        .{ 2048, 2048 },
    };
    const cs: f32 = @floatFromInt(shadow_cascade_size);

    for (0..cascade_count) |ci| {
        const light_vp = cascades.light_vp[ci];

        // Dispatch compute shader to build instance data with light VP.
        // shadow_pass=true zeros out non-caster entities (degenerate triangles).
        dispatchInstanceSetup(self, cmd, light_vp, frame.draw_count, true, false, false);

        // Render this cascade
        const color_target = c.SDL_GPUColorTargetInfo{
            .texture = shadow_atlas,
            .mip_level = 0,
            .layer_or_depth_plane = 0,
            .clear_color = .{ .r = 1.0, .g = 0, .b = 0, .a = 0 },
            .load_op = if (ci == 0) c.SDL_GPU_LOADOP_CLEAR else c.SDL_GPU_LOADOP_LOAD,
            .store_op = c.SDL_GPU_STOREOP_STORE,
            .resolve_texture = null,
            .resolve_mip_level = 0,
            .resolve_layer = 0,
            .cycle = false,
            .cycle_resolve_texture = false,
            .padding1 = 0,
            .padding2 = 0,
        };
        const depth_target = c.SDL_GPUDepthStencilTargetInfo{
            .texture = shadow_depth_tex,
            .clear_depth = 1.0,
            .load_op = if (ci == 0) c.SDL_GPU_LOADOP_CLEAR else c.SDL_GPU_LOADOP_LOAD,
            .store_op = c.SDL_GPU_STOREOP_STORE,
            .stencil_load_op = c.SDL_GPU_LOADOP_DONT_CARE,
            .stencil_store_op = c.SDL_GPU_STOREOP_DONT_CARE,
            .cycle = false,
            .clear_stencil = 0,
            .mip_level = 0,
            .layer = 0,
        };

        const render_pass = c.SDL_BeginGPURenderPass(cmd, &color_target, 1, &depth_target) orelse continue;
        c.SDL_BindGPUGraphicsPipeline(render_pass, shadow_pipe);

        const buf_ptr = [1]*c.SDL_GPUBuffer{gpu_buf};
        c.SDL_BindGPUVertexStorageBuffers(render_pass, 0, &buf_ptr, 1);

        c.SDL_SetGPUViewport(render_pass, &c.SDL_GPUViewport{
            .x = offsets_px[ci][0],
            .y = offsets_px[ci][1],
            .w = cs,
            .h = cs,
            .min_depth = 0.0,
            .max_depth = 1.0,
        });
        c.SDL_SetGPUScissor(render_pass, &c.SDL_Rect{
            .x = @intFromFloat(offsets_px[ci][0]),
            .y = @intFromFloat(offsets_px[ci][1]),
            .w = shadow_cascade_size,
            .h = shadow_cascade_size,
        });

        _ = submitShadowDrawCalls(self, render_pass, frame.draw_count);
        c.SDL_EndGPURenderPass(render_pass);
    }

    // Build ShadowUniforms for the fragment shader
    var uniforms: ShadowUniforms = undefined;
    for (0..cascade_count) |ci| {
        uniforms.light_vp[ci] = cascades.light_vp[ci].m;
    }
    uniforms.cascade_splits = cascades.splits;
    uniforms.shadow_params = .{
        @floatFromInt(shadow_atlas_size),
        @floatFromInt(shadow_cascade_size),
        0.005,
        1.0, // enabled
    };
    return uniforms;
}

/// Compute per-instance matrices and upload to GPU. Must be called before executeScenePass.
pub fn uploadInstanceData(self: *Engine, cmd: *c.SDL_GPUCommandBuffer, cam_entity: ecs.entity_t, w: u32, h: u32, frame: FrameContext) void {
    const vp = computeVP(self, cam_entity, w, h);
    uploadInstances(self, cmd, vp, frame.draw_count);
}

/// Execute the scene render pass (assumes instance data already uploaded).
pub fn executeScenePass(
    self: *Engine,
    cmd: *c.SDL_GPUCommandBuffer,
    cam_entity: ecs.entity_t,
    color_target_tex: *c.SDL_GPUTexture,
    w: u32,
    h: u32,
    frame: FrameContext,
    exposure: f32,
    shadow_uniforms: ShadowUniforms,
) void {
    if (self.depth_texture == null) return;

    const cam_pos = ecs.get(self.world, cam_entity, Position) orelse return;
    const cam = ecs.get(self.world, cam_entity, Camera) orelse return;
    const is_msaa = self.sample_count.isMultisample();

    const hdr_clear = srgbToHdr4(self.clear_color, exposure);
    const clear_color = c.SDL_FColor{ .r = hdr_clear[0], .g = hdr_clear[1], .b = hdr_clear[2], .a = 1000.0 };

    const normal_target_tex = self.normal_roughness_texture orelse return;
    const normal_clear = c.SDL_FColor{ .r = 0.5, .g = 0.5, .b = 1.0, .a = 1.0 }; // default normal=(0,0,1), roughness=1

    // Two color targets: [0] = HDR scene, [1] = normal+roughness
    const color_targets = if (is_msaa) [2]c.SDL_GPUColorTargetInfo{
        .{
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
        },
        .{
            .texture = self.msaa_normal_texture,
            .mip_level = 0,
            .layer_or_depth_plane = 0,
            .clear_color = normal_clear,
            .load_op = c.SDL_GPU_LOADOP_CLEAR,
            .store_op = c.SDL_GPU_STOREOP_RESOLVE_AND_STORE,
            .resolve_texture = normal_target_tex,
            .resolve_mip_level = 0,
            .resolve_layer = 0,
            .cycle = true,
            .cycle_resolve_texture = false,
            .padding1 = 0,
            .padding2 = 0,
        },
    } else [2]c.SDL_GPUColorTargetInfo{
        .{
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
        },
        .{
            .texture = normal_target_tex,
            .mip_level = 0,
            .layer_or_depth_plane = 0,
            .clear_color = normal_clear,
            .load_op = c.SDL_GPU_LOADOP_CLEAR,
            .store_op = c.SDL_GPU_STOREOP_STORE,
            .resolve_texture = null,
            .resolve_mip_level = 0,
            .resolve_layer = 0,
            .cycle = false,
            .cycle_resolve_texture = false,
            .padding1 = 0,
            .padding2 = 0,
        },
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

    const render_pass = c.SDL_BeginGPURenderPass(cmd, &color_targets, 2, &depth_target) orelse return;
    c.SDL_BindGPUGraphicsPipeline(render_pass, self.pipeline);

    // Bind clustered lighting storage buffers to fragment shader
    const frag_bufs = [3]*c.SDL_GPUBuffer{
        self.cluster_light_buffer.?,
        self.cluster_info_buffer.?,
        self.cluster_index_buffer.?,
    };
    c.SDL_BindGPUFragmentStorageBuffers(render_pass, 0, &frag_bufs, 3);

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
        .light_dir = frame.dir_light.dir,
        .camera_pos = .{ cam_pos.x, cam_pos.y, cam_pos.z, 0.0 },
        .fog_color = .{ hdr_fog[0], hdr_fog[1], hdr_fog[2], if (self.fog_enabled) 1.0 else 0.0 },
        .fog_params = .{ self.fog_start, self.fog_end, 0.0, 0.0 },
        .ambient = self.ambient_color,
        .light_color = frame.dir_light.color,
        .cluster_grid = .{
            @floatFromInt(cluster_x),
            @floatFromInt(cluster_y),
            @floatFromInt(cluster_z),
            @floatFromInt(self.cluster_light_count),
        },
        .cluster_depth = .{
            cam.near,
            cam.far,
            @log(cam.far / cam.near),
            0.0,
        },
        .cluster_screen = .{
            w_f,
            h_f,
            @as(f32, @floatFromInt(cluster_x)) / w_f,
            @as(f32, @floatFromInt(cluster_y)) / h_f,
        },
    };
    c.SDL_PushGPUFragmentUniformData(cmd, 0, &scene_uniforms, @sizeOf(SceneUniforms));
    c.SDL_PushGPUFragmentUniformData(cmd, 2, &shadow_uniforms, @sizeOf(ShadowUniforms));

    // Bind shadow atlas as the 6th texture sampler (index 5)
    if (self.shadow_atlas != null and self.shadow_sampler != null) {
        const shadow_binding = [1]c.SDL_GPUTextureSamplerBinding{
            .{ .texture = self.shadow_atlas.?, .sampler = self.shadow_sampler.? },
        };
        c.SDL_BindGPUFragmentSamplers(render_pass, 5, &shadow_binding, 1);
    }

    submitDrawCallsIndirect(self, cmd, render_pass);
    c.SDL_EndGPURenderPass(render_pass);
}
