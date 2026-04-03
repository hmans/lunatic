const std = @import("std");
const math3d = @import("math3d.zig");
const Mat4 = math3d.Mat4;
const Vec3 = math3d.Vec3;

const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("lua.h");
    @cInclude("lualib.h");
    @cInclude("lauxlib.h");
});

// ============================================================
// Vertex format: position + normal
// ============================================================

const Vertex = extern struct {
    px: f32,
    py: f32,
    pz: f32,
    nx: f32,
    ny: f32,
    nz: f32,
};

// ============================================================
// Built-in cube mesh (white albedo, face normals)
// ============================================================

fn vtx(px: f32, py: f32, pz: f32, nx: f32, ny: f32, nz: f32) Vertex {
    return .{ .px = px, .py = py, .pz = pz, .nx = nx, .ny = ny, .nz = nz };
}

const cube_vertices = [36]Vertex{
    // Front face (normal: 0, 0, 1)
    vtx(-0.5, -0.5, 0.5, 0, 0, 1), vtx(0.5, -0.5, 0.5, 0, 0, 1), vtx(0.5, 0.5, 0.5, 0, 0, 1),
    vtx(-0.5, -0.5, 0.5, 0, 0, 1), vtx(0.5, 0.5, 0.5, 0, 0, 1),  vtx(-0.5, 0.5, 0.5, 0, 0, 1),
    // Back face (normal: 0, 0, -1)
    vtx(0.5, -0.5, -0.5, 0, 0, -1),  vtx(-0.5, -0.5, -0.5, 0, 0, -1), vtx(-0.5, 0.5, -0.5, 0, 0, -1),
    vtx(0.5, -0.5, -0.5, 0, 0, -1),  vtx(-0.5, 0.5, -0.5, 0, 0, -1),  vtx(0.5, 0.5, -0.5, 0, 0, -1),
    // Top face (normal: 0, 1, 0)
    vtx(-0.5, 0.5, 0.5, 0, 1, 0),  vtx(0.5, 0.5, 0.5, 0, 1, 0),  vtx(0.5, 0.5, -0.5, 0, 1, 0),
    vtx(-0.5, 0.5, 0.5, 0, 1, 0),  vtx(0.5, 0.5, -0.5, 0, 1, 0), vtx(-0.5, 0.5, -0.5, 0, 1, 0),
    // Bottom face (normal: 0, -1, 0)
    vtx(-0.5, -0.5, -0.5, 0, -1, 0), vtx(0.5, -0.5, -0.5, 0, -1, 0), vtx(0.5, -0.5, 0.5, 0, -1, 0),
    vtx(-0.5, -0.5, -0.5, 0, -1, 0), vtx(0.5, -0.5, 0.5, 0, -1, 0),  vtx(-0.5, -0.5, 0.5, 0, -1, 0),
    // Right face (normal: 1, 0, 0)
    vtx(0.5, -0.5, 0.5, 1, 0, 0),  vtx(0.5, -0.5, -0.5, 1, 0, 0), vtx(0.5, 0.5, -0.5, 1, 0, 0),
    vtx(0.5, -0.5, 0.5, 1, 0, 0),  vtx(0.5, 0.5, -0.5, 1, 0, 0),  vtx(0.5, 0.5, 0.5, 1, 0, 0),
    // Left face (normal: -1, 0, 0)
    vtx(-0.5, -0.5, -0.5, -1, 0, 0), vtx(-0.5, -0.5, 0.5, -1, 0, 0),  vtx(-0.5, 0.5, 0.5, -1, 0, 0),
    vtx(-0.5, -0.5, -0.5, -1, 0, 0), vtx(-0.5, 0.5, 0.5, -1, 0, 0),   vtx(-0.5, 0.5, -0.5, -1, 0, 0),
};

// ============================================================
// Metal shaders (MSL)
// ============================================================

const vertex_shader_msl =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct Vertex {
    \\    float3 position [[attribute(0)]];
    \\    float3 normal   [[attribute(1)]];
    \\};
    \\
    \\struct VertexUniforms {
    \\    float4x4 mvp;
    \\    float4x4 model;
    \\};
    \\
    \\struct VertexOut {
    \\    float4 position [[position]];
    \\    float3 world_pos;
    \\    float3 world_normal;
    \\};
    \\
    \\vertex VertexOut vertex_main(
    \\    Vertex in [[stage_in]],
    \\    constant VertexUniforms &u [[buffer(0)]]
    \\) {
    \\    VertexOut out;
    \\    out.position = u.mvp * float4(in.position, 1.0);
    \\    out.world_pos = (u.model * float4(in.position, 1.0)).xyz;
    \\    out.world_normal = normalize((u.model * float4(in.normal, 0.0)).xyz);
    \\    return out;
    \\}
;

const fragment_shader_msl =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct VertexOut {
    \\    float4 position [[position]];
    \\    float3 world_pos;
    \\    float3 world_normal;
    \\};
    \\
    \\struct FragUniforms {
    \\    float4 light_dir;       // xyz = direction (toward light), w = unused
    \\    float4 camera_pos;      // xyz = eye position, w = unused
    \\    float4 fog_color;       // xyz = color, w = fog_start
    \\    float4 fog_params;      // x = fog_end, y = fog_enabled, zw = unused
    \\    float4 albedo;          // xyz = surface color, w = unused
    \\    float4 ambient;         // xyz = ambient color, w = unused
    \\};
    \\
    \\fragment float4 fragment_main(
    \\    VertexOut in [[stage_in]],
    \\    constant FragUniforms &u [[buffer(0)]]
    \\) {
    \\    // Directional light (half-Lambert for softer shading)
    \\    float3 N = normalize(in.world_normal);
    \\    float3 L = normalize(u.light_dir.xyz);
    \\    float ndotl = dot(N, L);
    \\    float diffuse = ndotl * 0.5 + 0.5; // half-Lambert wrap
    \\    diffuse = diffuse * diffuse;        // square for contrast
    \\
    \\    float3 color = u.albedo.xyz * (u.ambient.xyz + diffuse);
    \\
    \\    // Fog
    \\    if (u.fog_params.y > 0.5) {
    \\        float dist = length(in.world_pos - u.camera_pos.xyz);
    \\        float fog_start = u.fog_color.w;
    \\        float fog_end = u.fog_params.x;
    \\        float fog_factor = clamp((dist - fog_start) / (fog_end - fog_start), 0.0, 1.0);
    \\        color = mix(color, u.fog_color.xyz, fog_factor);
    \\    }
    \\
    \\    return float4(color, 1.0);
    \\}
;

// ============================================================
// Uniform structs (std140 layout — vec4 aligned)
// ============================================================

const VertexUniforms = extern struct {
    mvp: [4][4]f32,
    model: [4][4]f32,
};

const FragUniforms = extern struct {
    light_dir: [4]f32,     // xyz = direction, w = pad
    camera_pos: [4]f32,    // xyz = eye, w = pad
    fog_color: [4]f32,     // xyz = color, w = fog_start
    fog_params: [4]f32,    // x = fog_end, y = fog_enabled, zw = pad
    albedo: [4]f32,        // xyz = surface color, w = pad
    ambient: [4]f32,       // xyz = ambient light color, w = pad
};

// ============================================================
// Mesh registry
// ============================================================

const Mesh = struct {
    buffer: *c.SDL_GPUBuffer,
    vertex_count: u32,
};

const max_meshes = 64;
var meshes: [max_meshes]?Mesh = .{null} ** max_meshes;
var mesh_names: [max_meshes]?[*:0]const u8 = .{null} ** max_meshes;
var mesh_count: u32 = 0;

fn registerMesh(name: [*:0]const u8, buffer: *c.SDL_GPUBuffer, vertex_count: u32) u32 {
    const id = mesh_count;
    meshes[id] = .{ .buffer = buffer, .vertex_count = vertex_count };
    mesh_names[id] = name;
    mesh_count += 1;
    return id;
}

fn findMesh(name: [*:0]const u8) ?u32 {
    const needle = std.mem.span(name);
    for (0..mesh_count) |i| {
        if (mesh_names[i]) |n| {
            if (std.mem.eql(u8, std.mem.span(n), needle)) return @intCast(i);
        }
    }
    return null;
}

// ============================================================
// Per-frame draw list
// ============================================================

const DrawCmd = struct {
    mesh_id: u32,
    position: Vec3,
    rotation: Vec3,
};

const max_draws = 4096;
var draw_list: [max_draws]DrawCmd = undefined;
var draw_count: u32 = 0;

fn resetDrawList() void {
    draw_count = 0;
}

fn sortDrawList() void {
    std.mem.sort(DrawCmd, draw_list[0..draw_count], {}, struct {
        fn lessThan(_: void, a: DrawCmd, b: DrawCmd) bool {
            return a.mesh_id < b.mesh_id;
        }
    }.lessThan);
}

fn pushDraw(mesh_id: u32, pos: Vec3, rot: Vec3) void {
    if (draw_count >= max_draws) return;
    draw_list[draw_count] = .{ .mesh_id = mesh_id, .position = pos, .rotation = rot };
    draw_count += 1;
}

// ============================================================
// Engine globals
// ============================================================

var gpu_device: ?*c.SDL_GPUDevice = null;
var window: ?*c.SDL_Window = null;
var pipeline: ?*c.SDL_GPUGraphicsPipeline = null;
var depth_texture: ?*c.SDL_GPUTexture = null;

var camera_eye = Vec3.new(0, 1.5, 4);
var camera_target = Vec3.new(0, 0, 0);
var clear_color = [4]f32{ 0.08, 0.08, 0.12, 1.0 };

// Lighting
var light_dir = [4]f32{ 0.4, 0.8, 0.4, 0.0 }; // direction toward light
var ambient_color = [4]f32{ 0.15, 0.15, 0.2, 0.0 };

// Fog
var fog_enabled: bool = false;
var fog_start: f32 = 10.0;
var fog_end: f32 = 30.0;
var fog_color = [3]f32{ 0.08, 0.08, 0.12 }; // defaults to clear color

// ============================================================
// Lua API
// ============================================================

fn luaKeyDown(L: ?*c.lua_State) callconv(.c) c_int {
    const name = c.luaL_checklstring(L, 1, null);
    const scancode = c.SDL_GetScancodeFromName(name);
    const state = c.SDL_GetKeyboardState(null);
    c.lua_pushboolean(L, if (state[scancode]) 1 else 0);
    return 1;
}

fn luaSetCamera(L: ?*c.lua_State) callconv(.c) c_int {
    camera_eye.x = @floatCast(c.luaL_checknumber(L, 1));
    camera_eye.y = @floatCast(c.luaL_checknumber(L, 2));
    camera_eye.z = @floatCast(c.luaL_checknumber(L, 3));
    camera_target.x = @floatCast(c.luaL_checknumber(L, 4));
    camera_target.y = @floatCast(c.luaL_checknumber(L, 5));
    camera_target.z = @floatCast(c.luaL_checknumber(L, 6));
    return 0;
}

fn luaSetClearColor(L: ?*c.lua_State) callconv(.c) c_int {
    clear_color[0] = @floatCast(c.luaL_checknumber(L, 1));
    clear_color[1] = @floatCast(c.luaL_checknumber(L, 2));
    clear_color[2] = @floatCast(c.luaL_checknumber(L, 3));
    return 0;
}

/// gammo.set_fog(start, end, r, g, b) — enable fog
/// gammo.set_fog(false) — disable fog
fn luaSetFog(L: ?*c.lua_State) callconv(.c) c_int {
    if (c.lua_isboolean(L, 1) and c.lua_toboolean(L, 1) == 0) {
        fog_enabled = false;
        return 0;
    }
    fog_enabled = true;
    fog_start = @floatCast(c.luaL_checknumber(L, 1));
    fog_end = @floatCast(c.luaL_checknumber(L, 2));
    fog_color[0] = @floatCast(c.luaL_optnumber(L, 3, clear_color[0]));
    fog_color[1] = @floatCast(c.luaL_optnumber(L, 4, clear_color[1]));
    fog_color[2] = @floatCast(c.luaL_optnumber(L, 5, clear_color[2]));
    return 0;
}

/// gammo.set_light(dx, dy, dz) — set directional light direction (toward light)
fn luaSetLight(L: ?*c.lua_State) callconv(.c) c_int {
    light_dir[0] = @floatCast(c.luaL_checknumber(L, 1));
    light_dir[1] = @floatCast(c.luaL_checknumber(L, 2));
    light_dir[2] = @floatCast(c.luaL_checknumber(L, 3));
    return 0;
}

/// gammo.set_ambient(r, g, b) — set ambient light color
fn luaSetAmbient(L: ?*c.lua_State) callconv(.c) c_int {
    ambient_color[0] = @floatCast(c.luaL_checknumber(L, 1));
    ambient_color[1] = @floatCast(c.luaL_checknumber(L, 2));
    ambient_color[2] = @floatCast(c.luaL_checknumber(L, 3));
    return 0;
}

fn luaDrawMesh(L: ?*c.lua_State) callconv(.c) c_int {
    const name = c.luaL_checklstring(L, 1, null);
    const mesh_id = findMesh(name) orelse {
        _ = c.luaL_error(L, "unknown mesh: %s", name);
        return 0;
    };
    const pos = Vec3.new(
        @floatCast(c.luaL_optnumber(L, 2, 0)),
        @floatCast(c.luaL_optnumber(L, 3, 0)),
        @floatCast(c.luaL_optnumber(L, 4, 0)),
    );
    const rot = Vec3.new(
        @floatCast(c.luaL_optnumber(L, 5, 0)),
        @floatCast(c.luaL_optnumber(L, 6, 0)),
        @floatCast(c.luaL_optnumber(L, 7, 0)),
    );
    pushDraw(mesh_id, pos, rot);
    return 0;
}

const gammo_lib = [_]c.luaL_Reg{
    .{ .name = "key_down", .func = luaKeyDown },
    .{ .name = "set_camera", .func = luaSetCamera },
    .{ .name = "set_clear_color", .func = luaSetClearColor },
    .{ .name = "set_fog", .func = luaSetFog },
    .{ .name = "set_light", .func = luaSetLight },
    .{ .name = "set_ambient", .func = luaSetAmbient },
    .{ .name = "draw_mesh", .func = luaDrawMesh },
    .{ .name = null, .func = null },
};

// ============================================================
// GPU helpers
// ============================================================

fn createShader(device: *c.SDL_GPUDevice, code: [*:0]const u8, stage: c.SDL_GPUShaderStage, num_uniform_buffers: u32) ?*c.SDL_GPUShader {
    const info = c.SDL_GPUShaderCreateInfo{
        .code_size = std.mem.len(code),
        .code = code,
        .entrypoint = if (stage == c.SDL_GPU_SHADERSTAGE_VERTEX) "vertex_main" else "fragment_main",
        .format = c.SDL_GPU_SHADERFORMAT_MSL,
        .stage = stage,
        .num_samplers = 0,
        .num_storage_textures = 0,
        .num_storage_buffers = 0,
        .num_uniform_buffers = num_uniform_buffers,
        .props = 0,
    };
    return c.SDL_CreateGPUShader(device, &info);
}

fn uploadVertexData(device: *c.SDL_GPUDevice, data: []const u8) ?*c.SDL_GPUBuffer {
    const data_size: u32 = @intCast(data.len);

    const buf = c.SDL_CreateGPUBuffer(device, &c.SDL_GPUBufferCreateInfo{
        .usage = c.SDL_GPU_BUFFERUSAGE_VERTEX,
        .size = data_size,
        .props = 0,
    }) orelse return null;

    const transfer = c.SDL_CreateGPUTransferBuffer(device, &c.SDL_GPUTransferBufferCreateInfo{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = data_size,
        .props = 0,
    }) orelse return null;

    const ptr = c.SDL_MapGPUTransferBuffer(device, transfer, false) orelse return null;
    @memcpy(@as([*]u8, @ptrCast(ptr))[0..data_size], data);
    c.SDL_UnmapGPUTransferBuffer(device, transfer);

    const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse return null;
    const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse return null;
    c.SDL_UploadToGPUBuffer(copy_pass, &c.SDL_GPUTransferBufferLocation{
        .transfer_buffer = transfer,
        .offset = 0,
    }, &c.SDL_GPUBufferRegion{
        .buffer = buf,
        .offset = 0,
        .size = data_size,
    }, false);
    c.SDL_EndGPUCopyPass(copy_pass);
    _ = c.SDL_SubmitGPUCommandBuffer(cmd);

    c.SDL_ReleaseGPUTransferBuffer(device, transfer);
    return buf;
}

fn createDepthTexture(device: *c.SDL_GPUDevice, w: u32, h: u32) ?*c.SDL_GPUTexture {
    return c.SDL_CreateGPUTexture(device, &c.SDL_GPUTextureCreateInfo{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = c.SDL_GPU_TEXTUREFORMAT_D32_FLOAT,
        .usage = c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET,
        .width = w,
        .height = h,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
        .props = 0,
    });
}

// ============================================================
// Main
// ============================================================

pub fn main() !void {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.debug.print("SDL_Init failed: {s}\n", .{c.SDL_GetError()});
        return error.SDLInitFailed;
    }
    defer c.SDL_Quit();

    gpu_device = c.SDL_CreateGPUDevice(c.SDL_GPU_SHADERFORMAT_MSL, true, null);
    if (gpu_device == null) {
        std.debug.print("SDL_CreateGPUDevice failed: {s}\n", .{c.SDL_GetError()});
        return error.GPUDeviceFailed;
    }
    const device = gpu_device.?;
    defer c.SDL_DestroyGPUDevice(device);

    window = c.SDL_CreateWindow("gammo", 800, 600, 0);
    if (window == null) {
        std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
        return error.SDLWindowFailed;
    }
    defer c.SDL_DestroyWindow(window);

    if (!c.SDL_ClaimWindowForGPUDevice(device, window)) {
        std.debug.print("SDL_ClaimWindowForGPUDevice failed: {s}\n", .{c.SDL_GetError()});
        return error.ClaimWindowFailed;
    }

    // Shaders — vertex has 1 uniform buffer, fragment has 1 uniform buffer
    const vert_shader = createShader(device, vertex_shader_msl, c.SDL_GPU_SHADERSTAGE_VERTEX, 1) orelse {
        std.debug.print("Failed to create vertex shader: {s}\n", .{c.SDL_GetError()});
        return error.ShaderFailed;
    };
    defer c.SDL_ReleaseGPUShader(device, vert_shader);

    const frag_shader = createShader(device, fragment_shader_msl, c.SDL_GPU_SHADERSTAGE_FRAGMENT, 1) orelse {
        std.debug.print("Failed to create fragment shader: {s}\n", .{c.SDL_GetError()});
        return error.ShaderFailed;
    };
    defer c.SDL_ReleaseGPUShader(device, frag_shader);

    // Pipeline
    const swapchain_format = c.SDL_GetGPUSwapchainTextureFormat(device, window);

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

    pipeline = c.SDL_CreateGPUGraphicsPipeline(device, &c.SDL_GPUGraphicsPipelineCreateInfo{
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
    defer c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);

    // Register built-in meshes
    const cube_buf = uploadVertexData(device, std.mem.asBytes(&cube_vertices)) orelse {
        std.debug.print("Failed to upload cube mesh: {s}\n", .{c.SDL_GetError()});
        return error.BufferFailed;
    };
    _ = registerMesh("cube", cube_buf, cube_vertices.len);

    // Depth texture
    depth_texture = createDepthTexture(device, 800, 600) orelse {
        std.debug.print("Failed to create depth texture: {s}\n", .{c.SDL_GetError()});
        return error.DepthTextureFailed;
    };
    defer c.SDL_ReleaseGPUTexture(device, depth_texture);

    // Lua init
    const L = c.luaL_newstate() orelse return error.LuaInitFailed;
    defer c.lua_close(L);
    c.luaL_openlibs(L);

    c.luaL_register(L, "gammo", &gammo_lib);
    c.lua_pop(L, 1);

    _ = c.luaL_dostring(L, "package.path = 'game/?.lua;' .. package.path");

    if (c.luaL_loadfile(L, "game/main.lua") != 0 or c.lua_pcall(L, 0, 0, 0) != 0) {
        const err = c.lua_tolstring(L, -1, null);
        std.debug.print("Lua error: {s}\n", .{err});
        return error.LuaLoadFailed;
    }

    callLua(L, "init", 0);

    // Game loop
    var running = true;
    var last_time = c.SDL_GetPerformanceCounter();
    const freq: f64 = @floatFromInt(c.SDL_GetPerformanceFrequency());
    const dt_smoothing = 0.1;
    const dt_max = 0.25;
    var smooth_dt: f64 = 1.0 / 60.0;

    while (running) {
        const now = c.SDL_GetPerformanceCounter();
        const raw_dt = @min(@as(f64, @floatFromInt(now - last_time)) / freq, dt_max);
        last_time = now;
        smooth_dt += dt_smoothing * (raw_dt - smooth_dt);
        const dt = smooth_dt;

        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            if (event.type == c.SDL_EVENT_QUIT) running = false;
            if (event.type == c.SDL_EVENT_KEY_DOWN and event.key.scancode == c.SDL_SCANCODE_ESCAPE) running = false;
        }

        // Lua update
        _ = c.lua_getglobal(L, "update");
        c.lua_pushnumber(L, dt);
        if (c.lua_pcall(L, 1, 0, 0) != 0) {
            const err = c.lua_tolstring(L, -1, null);
            std.debug.print("Lua update error: {s}\n", .{err});
            c.lua_pop(L, 1);
        }

        // Lua draw
        resetDrawList();
        callLua(L, "draw", 0);

        // Render
        const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse continue;

        var swapchain_tex: ?*c.SDL_GPUTexture = null;
        var sw_w: u32 = 0;
        var sw_h: u32 = 0;
        if (!c.SDL_AcquireGPUSwapchainTexture(cmd, window, &swapchain_tex, &sw_w, &sw_h)) {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            continue;
        }
        if (swapchain_tex == null) {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            continue;
        }

        const aspect: f32 = @as(f32, @floatFromInt(sw_w)) / @as(f32, @floatFromInt(sw_h));
        const proj = Mat4.perspective(60.0, aspect, 0.1, 100.0);
        const view = Mat4.lookAt(camera_eye, camera_target, Vec3.new(0, 1, 0));
        const vp = Mat4.mul(proj, view);

        // Build fragment uniforms (same for all draws this frame)
        const frag_uniforms = FragUniforms{
            .light_dir = light_dir,
            .camera_pos = .{ camera_eye.x, camera_eye.y, camera_eye.z, 0.0 },
            .fog_color = .{ fog_color[0], fog_color[1], fog_color[2], fog_start },
            .fog_params = .{ fog_end, if (fog_enabled) 1.0 else 0.0, 0.0, 0.0 },
            .albedo = .{ 1.0, 1.0, 1.0, 0.0 },
            .ambient = ambient_color,
        };

        const color_target = c.SDL_GPUColorTargetInfo{
            .texture = swapchain_tex,
            .mip_level = 0,
            .layer_or_depth_plane = 0,
            .clear_color = .{ .r = clear_color[0], .g = clear_color[1], .b = clear_color[2], .a = clear_color[3] },
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

        const depth_target = c.SDL_GPUDepthStencilTargetInfo{
            .texture = depth_texture,
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

        const render_pass = c.SDL_BeginGPURenderPass(cmd, &color_target, 1, &depth_target) orelse {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            continue;
        };

        c.SDL_BindGPUGraphicsPipeline(render_pass, pipeline);

        // Push fragment uniforms once per frame
        c.SDL_PushGPUFragmentUniformData(cmd, 0, &frag_uniforms, @sizeOf(FragUniforms));

        sortDrawList();

        var bound_mesh: ?u32 = null;
        for (0..draw_count) |i| {
            const draw = draw_list[i];
            const mesh = meshes[draw.mesh_id] orelse continue;

            if (bound_mesh == null or bound_mesh.? != draw.mesh_id) {
                const binding = c.SDL_GPUBufferBinding{ .buffer = mesh.buffer, .offset = 0 };
                c.SDL_BindGPUVertexBuffers(render_pass, 0, &binding, 1);
                bound_mesh = draw.mesh_id;
            }

            const rotation = Mat4.mul(
                Mat4.rotateY(draw.rotation.y),
                Mat4.rotateX(draw.rotation.x),
            );
            const model = Mat4.mul(
                Mat4.translate(draw.position.x, draw.position.y, draw.position.z),
                rotation,
            );
            const mvp = Mat4.mul(vp, model);

            const vert_uniforms = VertexUniforms{
                .mvp = mvp.m,
                .model = model.m,
            };

            c.SDL_PushGPUVertexUniformData(cmd, 0, &vert_uniforms, @sizeOf(VertexUniforms));
            c.SDL_DrawGPUPrimitives(render_pass, mesh.vertex_count, 1, 0, 0);
        }

        c.SDL_EndGPURenderPass(render_pass);
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
    }
}

fn callLua(L: *c.lua_State, name: [*:0]const u8, nargs: c_int) void {
    _ = c.lua_getglobal(L, name);
    if (c.lua_pcall(L, nargs, 0, 0) != 0) {
        const err = c.lua_tolstring(L, -1, null);
        std.debug.print("Lua {s}() error: {s}\n", .{ name, err });
        c.lua_pop(L, 1);
    }
}
