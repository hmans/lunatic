// engine.zig — Lunatic engine core. Import this as a library.

const std = @import("std");
const builtin = @import("builtin");
const math3d = @import("math3d.zig");
const components = @import("components.zig");
const ecs = @import("zig-ecs");
const Mat4 = math3d.Mat4;
const Vec3 = math3d.Vec3;

const lua = @import("lua.zig");
const lc = lua.c;
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

// Re-export component types
const Position = components.Position;
const Rotation = components.Rotation;
const MeshHandle = components.MeshHandle;
const Spin = components.Spin;

// ============================================================
// Vertex format
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
// Built-in cube mesh
// ============================================================

fn vtx(px: f32, py: f32, pz: f32, nx: f32, ny: f32, nz: f32) Vertex {
    return .{ .px = px, .py = py, .pz = pz, .nx = nx, .ny = ny, .nz = nz };
}

const cube_vertices = [36]Vertex{
    vtx(-0.5, -0.5, 0.5, 0, 0, 1), vtx(0.5, -0.5, 0.5, 0, 0, 1), vtx(0.5, 0.5, 0.5, 0, 0, 1),
    vtx(-0.5, -0.5, 0.5, 0, 0, 1), vtx(0.5, 0.5, 0.5, 0, 0, 1),  vtx(-0.5, 0.5, 0.5, 0, 0, 1),
    vtx(0.5, -0.5, -0.5, 0, 0, -1),  vtx(-0.5, -0.5, -0.5, 0, 0, -1), vtx(-0.5, 0.5, -0.5, 0, 0, -1),
    vtx(0.5, -0.5, -0.5, 0, 0, -1),  vtx(-0.5, 0.5, -0.5, 0, 0, -1),  vtx(0.5, 0.5, -0.5, 0, 0, -1),
    vtx(-0.5, 0.5, 0.5, 0, 1, 0),  vtx(0.5, 0.5, 0.5, 0, 1, 0),  vtx(0.5, 0.5, -0.5, 0, 1, 0),
    vtx(-0.5, 0.5, 0.5, 0, 1, 0),  vtx(0.5, 0.5, -0.5, 0, 1, 0), vtx(-0.5, 0.5, -0.5, 0, 1, 0),
    vtx(-0.5, -0.5, -0.5, 0, -1, 0), vtx(0.5, -0.5, -0.5, 0, -1, 0), vtx(0.5, -0.5, 0.5, 0, -1, 0),
    vtx(-0.5, -0.5, -0.5, 0, -1, 0), vtx(0.5, -0.5, 0.5, 0, -1, 0),  vtx(-0.5, -0.5, 0.5, 0, -1, 0),
    vtx(0.5, -0.5, 0.5, 1, 0, 0),  vtx(0.5, -0.5, -0.5, 1, 0, 0), vtx(0.5, 0.5, -0.5, 1, 0, 0),
    vtx(0.5, -0.5, 0.5, 1, 0, 0),  vtx(0.5, 0.5, -0.5, 1, 0, 0),  vtx(0.5, 0.5, 0.5, 1, 0, 0),
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
    \\    float4 light_dir;
    \\    float4 camera_pos;
    \\    float4 fog_color;
    \\    float4 fog_params;
    \\    float4 albedo;
    \\    float4 ambient;
    \\};
    \\
    \\fragment float4 fragment_main(
    \\    VertexOut in [[stage_in]],
    \\    constant FragUniforms &u [[buffer(0)]]
    \\) {
    \\    float3 N = normalize(in.world_normal);
    \\    float3 L = normalize(u.light_dir.xyz);
    \\    float ndotl = dot(N, L);
    \\    float diffuse = ndotl * 0.5 + 0.5;
    \\    diffuse = diffuse * diffuse;
    \\
    \\    float3 color = u.albedo.xyz * (u.ambient.xyz + diffuse);
    \\
    \\    if (u.fog_color.w > 0.5) {
    \\        float dist = length(in.world_pos - u.camera_pos.xyz);
    \\        float fog_start = u.fog_params.x;
    \\        float fog_end = u.fog_params.y;
    \\        float fog_factor = clamp((dist - fog_start) / (fog_end - fog_start), 0.0, 1.0);
    \\        color = mix(color, u.fog_color.xyz, fog_factor);
    \\    }
    \\
    \\    return float4(color, 1.0);
    \\}
;

// ============================================================
// Uniform structs
// ============================================================

const VertexUniforms = extern struct {
    mvp: [4][4]f32,
    model: [4][4]f32,
};

const FragUniforms = extern struct {
    light_dir: [4]f32,
    camera_pos: [4]f32,
    fog_color: [4]f32, // .xyz = color, .w = fog_enabled (1.0 or 0.0)
    fog_params: [4]f32, // .x = fog_start, .y = fog_end
    albedo: [4]f32,
    ambient: [4]f32,
};

// ============================================================
// Constants
// ============================================================

const MeshData = struct {
    buffer: *c.SDL_GPUBuffer,
    vertex_count: u32,
};

const max_meshes = 64;
const max_cached_queries = 64;
const max_lua_systems = 64;

const QueryCacheEntry = struct {
    lua_ref: c_int = lc.LUA_NOREF,
    frame: u64 = 0,
    hash: u64 = 0,
};

const ComponentRef = extern struct {
    entity_id: u32,
    type_tag: u8,
};

const ref_metatable_name: [*:0]const u8 = "lunatic_component_ref";

// ============================================================
// Query entry types (comptime-generated, no mutable state)
// ============================================================

const HasFn = *const fn (*ecs.Registry, ecs.Entity) bool;
const LenFn = *const fn (*ecs.Registry) usize;
const DataFn = *const fn (*ecs.Registry) []ecs.Entity;

const QueryEntry = struct {
    name: []const u8,
    hasFn: HasFn,
    lenFn: LenFn,
    dataFn: DataFn,
};

fn makeQueryEntries() [components.all.len]QueryEntry {
    var entries: [components.all.len]QueryEntry = undefined;
    inline for (components.all, 0..) |T, i| {
        entries[i] = .{
            .name = lua.nameOf(T),
            .hasFn = &struct {
                fn has(reg: *ecs.Registry, entity: ecs.Entity) bool {
                    return reg.has(T, entity);
                }
            }.has,
            .lenFn = &struct {
                fn len(reg: *ecs.Registry) usize {
                    return reg.len(T);
                }
            }.len,
            .dataFn = &struct {
                fn data(reg: *ecs.Registry) []ecs.Entity {
                    return reg.data(T);
                }
            }.data,
        };
    }
    return entries;
}

const query_entries = makeQueryEntries();

fn findQueryEntry(name: []const u8) ?QueryEntry {
    for (query_entries) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry;
    }
    return null;
}

fn queryHash(entries: []const QueryEntry, count: usize) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (0..count) |i| {
        for (entries[i].name) |byte| {
            h ^= byte;
            h *%= 0x100000001b3;
        }
        h ^= 0xff;
        h *%= 0x100000001b3;
    }
    return h;
}

// ============================================================
// GPU helpers (stateless)
// ============================================================

fn createShader(device: *c.SDL_GPUDevice, code: [*:0]const u8, stage: c.SDL_GPUShaderStage, num_uniform_buffers: u32) ?*c.SDL_GPUShader {
    return c.SDL_CreateGPUShader(device, &c.SDL_GPUShaderCreateInfo{
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
    });
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
    }) orelse {
        c.SDL_ReleaseGPUBuffer(device, buf);
        return null;
    };

    const ptr = c.SDL_MapGPUTransferBuffer(device, transfer, false) orelse {
        c.SDL_ReleaseGPUTransferBuffer(device, transfer);
        c.SDL_ReleaseGPUBuffer(device, buf);
        return null;
    };
    @memcpy(@as([*]u8, @ptrCast(ptr))[0..data_size], data);
    c.SDL_UnmapGPUTransferBuffer(device, transfer);

    const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse {
        c.SDL_ReleaseGPUTransferBuffer(device, transfer);
        c.SDL_ReleaseGPUBuffer(device, buf);
        return null;
    };
    const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse {
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
        c.SDL_ReleaseGPUTransferBuffer(device, transfer);
        c.SDL_ReleaseGPUBuffer(device, buf);
        return null;
    };
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
// Config
// ============================================================

pub const Config = struct {
    title: [*:0]const u8 = "lunatic",
    width: u32 = 800,
    height: u32 = 600,
    headless: bool = false,
};

// ============================================================
// Engine
// ============================================================

pub const Engine = struct {
    // ECS
    registry: ecs.Registry,

    // GPU (null when headless)
    gpu_device: ?*c.SDL_GPUDevice = null,
    sdl_window: ?*c.SDL_Window = null,
    pipeline: ?*c.SDL_GPUGraphicsPipeline = null,
    depth_texture: ?*c.SDL_GPUTexture = null,
    depth_w: u32 = 0,
    depth_h: u32 = 0,

    // Camera
    camera_eye: Vec3 = Vec3.new(0, 1.5, 4),
    camera_target: Vec3 = Vec3.new(0, 0, 0),
    clear_color: [4]f32 = .{ 0.08, 0.08, 0.12, 1.0 },

    // Lighting
    light_dir: [4]f32 = .{ 0.4, 0.8, 0.4, 0.0 },
    ambient_color: [4]f32 = .{ 0.15, 0.15, 0.2, 0.0 },

    // Fog
    fog_enabled: bool = false,
    fog_start: f32 = 10.0,
    fog_end: f32 = 30.0,
    fog_color: [3]f32 = .{ 0.08, 0.08, 0.12 },

    // Mesh registry
    mesh_registry: [max_meshes]?MeshData = .{null} ** max_meshes,
    mesh_names: [max_meshes]?[*:0]const u8 = .{null} ** max_meshes,
    mesh_count: u32 = 0,

    // Query cache
    current_frame: u64 = 0,
    query_cache: [max_cached_queries]QueryCacheEntry = .{QueryCacheEntry{}} ** max_cached_queries,

    // Lua
    lua_state: ?*lc.lua_State = null,
    lua_system_refs: [max_lua_systems]c_int = .{0} ** max_lua_systems,
    lua_system_disabled: [max_lua_systems]bool = .{false} ** max_lua_systems,
    lua_system_count: u32 = 0,

    // State
    headless: bool = false,

    // ---- Lifecycle ----

    /// Initialize the engine. Call on a stable pointer (var engine: Engine = undefined; try engine.init(.{})).
    pub fn init(self: *Engine, config: Config) !void {
        self.* = Engine{
            .registry = ecs.Registry.init(std.heap.c_allocator),
            .headless = config.headless,
        };
        errdefer self.registry.deinit();

        // Lua
        const L = lc.luaL_newstate() orelse return error.LuaInitFailed;
        self.lua_state = L;
        errdefer {
            lc.lua_close(L);
            self.lua_state = null;
        }
        lc.luaL_openlibs(L);
        self.registerLuaApi();
        _ = lc.luaL_dostring(L, "package.path = 'game/?.lua;' .. package.path");

        if (!config.headless) {
            try self.initGpu(config);
        }
    }

    pub fn deinit(self: *Engine) void {
        if (self.lua_state) |L| lc.lua_close(L);

        if (self.gpu_device) |device| {
            if (self.depth_texture) |dt| c.SDL_ReleaseGPUTexture(device, dt);
            if (self.pipeline) |p| c.SDL_ReleaseGPUGraphicsPipeline(device, p);
            if (self.sdl_window) |w| c.SDL_DestroyWindow(w);
            c.SDL_DestroyGPUDevice(device);
            c.SDL_Quit();
        }

        self.registry.deinit();
    }

    pub fn loadScript(self: *Engine, path: [*:0]const u8) !void {
        const L = self.lua_state.?;
        if (lc.luaL_loadfile(L, path) != 0 or lc.lua_pcall(L, 0, 0, 0) != 0) {
            const err = lc.lua_tolstring(L, -1, null);
            std.debug.print("Lua error: {s}\n", .{err});
            return error.LuaLoadFailed;
        }
    }

    pub fn run(self: *Engine) !void {
        const device = self.gpu_device orelse return error.NotInitialized;

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
            const dt: f32 = @floatCast(smooth_dt);

            self.current_frame += 1;

            var event: c.SDL_Event = undefined;
            while (c.SDL_PollEvent(&event)) {
                if (event.type == c.SDL_EVENT_QUIT) running = false;
                if (event.type == c.SDL_EVENT_KEY_DOWN and event.key.scancode == c.SDL_SCANCODE_ESCAPE) running = false;
            }

            self.runLuaSystems(dt);
            self.renderSystem(device);
        }
    }

    // ---- GPU init ----

    fn initGpu(self: *Engine, config: Config) !void {
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
            std.debug.print("SDL_Init failed: {s}\n", .{c.SDL_GetError()});
            return error.SDLInitFailed;
        }

        self.gpu_device = c.SDL_CreateGPUDevice(c.SDL_GPU_SHADERFORMAT_MSL, true, null);
        if (self.gpu_device == null) {
            std.debug.print("SDL_CreateGPUDevice failed: {s}\n", .{c.SDL_GetError()});
            return error.GPUDeviceFailed;
        }
        const device = self.gpu_device.?;

        self.sdl_window = c.SDL_CreateWindow(config.title, @intCast(config.width), @intCast(config.height), c.SDL_WINDOW_RESIZABLE);
        if (self.sdl_window == null) {
            std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
            return error.SDLWindowFailed;
        }

        if (!c.SDL_ClaimWindowForGPUDevice(device, self.sdl_window)) {
            std.debug.print("SDL_ClaimWindowForGPUDevice failed: {s}\n", .{c.SDL_GetError()});
            return error.ClaimWindowFailed;
        }

        // Shaders (released after pipeline creation)
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
        const swapchain_format = c.SDL_GetGPUSwapchainTextureFormat(device, self.sdl_window);

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

        // Built-in meshes
        const cube_buf = uploadVertexData(device, std.mem.asBytes(&cube_vertices)) orelse {
            std.debug.print("Failed to upload cube mesh: {s}\n", .{c.SDL_GetError()});
            return error.BufferFailed;
        };
        _ = self.registerMesh("cube", cube_buf, cube_vertices.len);

        // Depth texture
        self.depth_texture = createDepthTexture(device, config.width, config.height) orelse {
            std.debug.print("Failed to create depth texture: {s}\n", .{c.SDL_GetError()});
            return error.DepthTextureFailed;
        };
        self.depth_w = config.width;
        self.depth_h = config.height;
    }

    // ---- Mesh registry ----

    fn registerMesh(self: *Engine, name: [*:0]const u8, buffer: *c.SDL_GPUBuffer, vertex_count: u32) u32 {
        const id = self.mesh_count;
        self.mesh_registry[id] = .{ .buffer = buffer, .vertex_count = vertex_count };
        self.mesh_names[id] = name;
        self.mesh_count += 1;
        return id;
    }

    fn findMesh(self: *Engine, name: [*:0]const u8) ?u32 {
        const needle = std.mem.span(name);
        for (0..self.mesh_count) |i| {
            if (self.mesh_names[i]) |n| {
                if (std.mem.eql(u8, std.mem.span(n), needle)) return @intCast(i);
            }
        }
        return null;
    }

    // ---- Query cache ----

    fn findCachedQuery(self: *Engine, hash: u64) ?usize {
        for (0..max_cached_queries) |i| {
            if (self.query_cache[i].hash == hash and self.query_cache[i].frame == self.current_frame) {
                return i;
            }
        }
        return null;
    }

    fn findCacheSlot(self: *Engine, hash: u64) usize {
        for (0..max_cached_queries) |i| {
            if (self.query_cache[i].hash == hash) return i;
        }
        var oldest_idx: usize = 0;
        var oldest_frame: u64 = std.math.maxInt(u64);
        for (0..max_cached_queries) |i| {
            if (self.query_cache[i].lua_ref == lc.LUA_NOREF) return i;
            if (self.query_cache[i].frame < oldest_frame) {
                oldest_frame = self.query_cache[i].frame;
                oldest_idx = i;
            }
        }
        if (self.query_cache[oldest_idx].lua_ref != lc.LUA_NOREF) {
            if (self.lua_state) |L| {
                lc.luaL_unref(L, lc.LUA_REGISTRYINDEX, self.query_cache[oldest_idx].lua_ref);
            }
            self.query_cache[oldest_idx].lua_ref = lc.LUA_NOREF;
        }
        return oldest_idx;
    }

    fn buildQueryTable(self: *Engine, L: ?*lc.lua_State, entries: []const QueryEntry, count: usize) void {
        var smallest_idx: usize = 0;
        var smallest_len: usize = entries[0].lenFn(&self.registry);
        for (1..count) |i| {
            const l = entries[i].lenFn(&self.registry);
            if (l < smallest_len) {
                smallest_len = l;
                smallest_idx = i;
            }
        }

        const entity_list = entries[smallest_idx].dataFn(&self.registry);
        lc.lua_createtable(L, @intCast(smallest_len), 0);
        var table_idx: c_int = 1;

        for (entity_list) |entity| {
            var match = true;
            for (0..count) |i| {
                if (i == smallest_idx) continue;
                if (!entries[i].hasFn(&self.registry, entity)) {
                    match = false;
                    break;
                }
            }
            if (match) {
                const entity_int: u32 = @bitCast(entity);
                lc.lua_pushinteger(L, @intCast(entity_int));
                lc.lua_rawseti(L, -2, table_idx);
                table_idx += 1;
            }
        }
    }

    // ---- Lua systems ----

    pub fn runLuaSystems(self: *Engine, dt: f32) void {
        const L = self.lua_state orelse return;
        for (0..self.lua_system_count) |i| {
            if (self.lua_system_disabled[i]) continue;
            lc.lua_rawgeti(L, lc.LUA_REGISTRYINDEX, self.lua_system_refs[i]);
            lc.lua_pushnumber(L, dt);
            if (lc.lua_pcall(L, 1, 0, 0) != 0) {
                if (comptime !builtin.is_test) {
                    const err = lc.lua_tolstring(L, -1, null);
                    std.debug.print("Lua system error (disabling): {s}\n", .{err});
                }
                lc.lua_pop(L, 1);
                self.lua_system_disabled[i] = true;
            }
        }
    }

    pub fn resetSystems(self: *Engine) void {
        self.lua_system_count = 0;
        self.lua_system_disabled = .{false} ** max_lua_systems;
    }

    // ---- Render system ----

    fn renderSystem(self: *Engine, device: *c.SDL_GPUDevice) void {
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

        // Recreate depth texture if swapchain dimensions changed
        if (sw_w != self.depth_w or sw_h != self.depth_h) {
            if (self.depth_texture) |dt| c.SDL_ReleaseGPUTexture(device, dt);
            self.depth_texture = createDepthTexture(device, sw_w, sw_h);
            self.depth_w = sw_w;
            self.depth_h = sw_h;
            if (self.depth_texture == null) {
                _ = c.SDL_SubmitGPUCommandBuffer(cmd);
                return;
            }
        }

        const aspect: f32 = @as(f32, @floatFromInt(sw_w)) / @as(f32, @floatFromInt(sw_h));
        const proj = Mat4.perspective(60.0, aspect, 0.1, 100.0);
        const view = Mat4.lookAt(self.camera_eye, self.camera_target, Vec3.new(0, 1, 0));
        const vp = Mat4.mul(proj, view);

        const frag_uniforms = FragUniforms{
            .light_dir = self.light_dir,
            .camera_pos = .{ self.camera_eye.x, self.camera_eye.y, self.camera_eye.z, 0.0 },
            .fog_color = .{ self.fog_color[0], self.fog_color[1], self.fog_color[2], if (self.fog_enabled) 1.0 else 0.0 },
            .fog_params = .{ self.fog_start, self.fog_end, 0.0, 0.0 },
            .albedo = .{ 1.0, 1.0, 1.0, 0.0 },
            .ambient = self.ambient_color,
        };

        const color_target = c.SDL_GPUColorTargetInfo{
            .texture = swapchain_tex,
            .mip_level = 0,
            .layer_or_depth_plane = 0,
            .clear_color = .{ .r = self.clear_color[0], .g = self.clear_color[1], .b = self.clear_color[2], .a = self.clear_color[3] },
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

        const render_pass = c.SDL_BeginGPURenderPass(cmd, &color_target, 1, &depth_target) orelse {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            return;
        };

        c.SDL_BindGPUGraphicsPipeline(render_pass, self.pipeline);
        c.SDL_PushGPUFragmentUniformData(cmd, 0, &frag_uniforms, @sizeOf(FragUniforms));

        var ecs_view = self.registry.view(.{ Position, Rotation, MeshHandle }, .{});
        var iter = ecs_view.entityIterator();

        var bound_mesh: ?u32 = null;
        while (iter.next()) |entity| {
            const pos = ecs_view.getConst(Position, entity);
            const rot = ecs_view.getConst(Rotation, entity);
            const mesh_handle = ecs_view.getConst(MeshHandle, entity);
            const mesh = self.mesh_registry[mesh_handle.id] orelse continue;

            if (bound_mesh == null or bound_mesh.? != mesh_handle.id) {
                const binding = c.SDL_GPUBufferBinding{ .buffer = mesh.buffer, .offset = 0 };
                c.SDL_BindGPUVertexBuffers(render_pass, 0, &binding, 1);
                bound_mesh = mesh_handle.id;
            }

            const rotation = Mat4.mul(Mat4.mul(Mat4.rotateZ(rot.z), Mat4.rotateY(rot.y)), Mat4.rotateX(rot.x));
            const model = Mat4.mul(Mat4.translate(pos.x, pos.y, pos.z), rotation);
            const mvp = Mat4.mul(vp, model);

            const vert_uniforms = VertexUniforms{ .mvp = mvp.m, .model = model.m };
            c.SDL_PushGPUVertexUniformData(cmd, 0, &vert_uniforms, @sizeOf(VertexUniforms));
            c.SDL_DrawGPUPrimitives(render_pass, mesh.vertex_count, 1, 0, 0);
        }

        c.SDL_EndGPURenderPass(render_pass);
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
    }

    // ---- Lua API registration ----

    fn registerLuaApi(self: *Engine) void {
        const L = self.lua_state.?;
        const self_ptr: *anyopaque = @ptrCast(self);

        // Create "lunatic" global table with closures
        lc.lua_newtable(L);

        const fns = .{
            .{ "key_down", &luaKeyDown },
            .{ "set_camera", &luaSetCamera },
            .{ "set_clear_color", &luaSetClearColor },
            .{ "set_fog", &luaSetFog },
            .{ "set_light", &luaSetLight },
            .{ "set_ambient", &luaSetAmbient },
            .{ "spawn", &luaSpawn },
            .{ "destroy", &luaDestroy },
            .{ "add", &luaAdd },
            .{ "get", &luaGet },
            .{ "remove", &luaRemove },
            .{ "query", &luaQuery },
            .{ "ref", &luaRef },
            .{ "system", &luaSystemRegister },
        };

        inline for (fns) |entry| {
            lc.lua_pushlightuserdata(L, self_ptr);
            lc.lua_pushcclosure(L, entry[1], 1);
            lc.lua_setfield(L, -2, entry[0]);
        }

        lc.lua_setglobal(L, "lunatic");

        // Ref metatable with closures
        _ = lc.luaL_newmetatable(L, ref_metatable_name);

        lc.lua_pushlightuserdata(L, self_ptr);
        lc.lua_pushcclosure(L, &refIndex, 1);
        lc.lua_setfield(L, -2, "__index");

        lc.lua_pushlightuserdata(L, self_ptr);
        lc.lua_pushcclosure(L, &refNewIndex, 1);
        lc.lua_setfield(L, -2, "__newindex");

        lc.lua_pop(L, 1);
    }
};

// ============================================================
// Lua C callbacks — module-level (Lua needs plain function pointers)
// ============================================================

/// Retrieve the Engine pointer from the first upvalue of the calling closure.
fn getEngine(L: ?*lc.lua_State) *Engine {
    return @ptrCast(@alignCast(lc.lua_touserdata(L, lc.LUA_GLOBALSINDEX - 1)));
}

fn entityFromLua(self: *Engine, L: ?*lc.lua_State, idx: c_int) ecs.Entity {
    const id: u32 = @intCast(lc.luaL_checkinteger(L, idx));
    const entity: ecs.Entity = @bitCast(id);
    if (!self.registry.valid(entity)) {
        _ = lc.luaL_error(L, "invalid entity %d", @as(c_int, @intCast(id)));
    }
    return entity;
}

fn componentName(L: ?*lc.lua_State, idx: c_int) []const u8 {
    return std.mem.span(lc.luaL_checklstring(L, idx, null));
}

fn luaKeyDown(L: ?*lc.lua_State) callconv(.c) c_int {
    _ = getEngine(L); // validate upvalue; key_down doesn't need engine state
    const name = lc.luaL_checklstring(L, 1, null);
    const scancode = c.SDL_GetScancodeFromName(name);
    const state = c.SDL_GetKeyboardState(null);
    lc.lua_pushboolean(L, if (state[scancode]) 1 else 0);
    return 1;
}

fn luaSetCamera(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    self.camera_eye.x = @floatCast(lc.luaL_checknumber(L, 1));
    self.camera_eye.y = @floatCast(lc.luaL_checknumber(L, 2));
    self.camera_eye.z = @floatCast(lc.luaL_checknumber(L, 3));
    self.camera_target.x = @floatCast(lc.luaL_checknumber(L, 4));
    self.camera_target.y = @floatCast(lc.luaL_checknumber(L, 5));
    self.camera_target.z = @floatCast(lc.luaL_checknumber(L, 6));
    return 0;
}

fn luaSetClearColor(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    self.clear_color[0] = @floatCast(lc.luaL_checknumber(L, 1));
    self.clear_color[1] = @floatCast(lc.luaL_checknumber(L, 2));
    self.clear_color[2] = @floatCast(lc.luaL_checknumber(L, 3));
    return 0;
}

fn luaSetFog(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    if (lc.lua_isboolean(L, 1) and lc.lua_toboolean(L, 1) == 0) {
        self.fog_enabled = false;
        return 0;
    }
    self.fog_enabled = true;
    self.fog_start = @floatCast(lc.luaL_checknumber(L, 1));
    self.fog_end = @floatCast(lc.luaL_checknumber(L, 2));
    self.fog_color[0] = @floatCast(lc.luaL_optnumber(L, 3, self.clear_color[0]));
    self.fog_color[1] = @floatCast(lc.luaL_optnumber(L, 4, self.clear_color[1]));
    self.fog_color[2] = @floatCast(lc.luaL_optnumber(L, 5, self.clear_color[2]));
    return 0;
}

fn luaSetLight(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    self.light_dir[0] = @floatCast(lc.luaL_checknumber(L, 1));
    self.light_dir[1] = @floatCast(lc.luaL_checknumber(L, 2));
    self.light_dir[2] = @floatCast(lc.luaL_checknumber(L, 3));
    return 0;
}

fn luaSetAmbient(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    self.ambient_color[0] = @floatCast(lc.luaL_checknumber(L, 1));
    self.ambient_color[1] = @floatCast(lc.luaL_checknumber(L, 2));
    self.ambient_color[2] = @floatCast(lc.luaL_checknumber(L, 3));
    return 0;
}

fn luaSpawn(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const entity = self.registry.create();
    const entity_int: u32 = @bitCast(entity);
    lc.lua_pushinteger(L, @intCast(entity_int));
    return 1;
}

fn luaDestroy(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const entity = entityFromLua(self, L, 1);
    self.registry.destroy(entity);
    return 0;
}

fn luaAdd(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const entity = entityFromLua(self, L, 1);
    const name = componentName(L, 2);

    inline for (components.all) |T| {
        if (std.mem.eql(u8, name, lua.nameOf(T))) {
            if (comptime lua.isTag(T)) {
                self.registry.addOrReplace(entity, T{});
                return 0;
            } else if (comptime @hasDecl(T, "Lua")) {
                self.registry.addOrReplace(entity, T.Lua.fromLua(L, 3));
                return 0;
            }
        }
    }

    // Components without auto-bindings (special cases)
    if (std.mem.eql(u8, name, lua.nameOf(MeshHandle))) {
        const mesh_name = lc.luaL_checklstring(L, 3, null);
        const mesh_id = self.findMesh(mesh_name) orelse {
            _ = lc.luaL_error(L, "unknown mesh: %s", mesh_name);
            return 0;
        };
        self.registry.addOrReplace(entity, MeshHandle{ .id = mesh_id });
        return 0;
    }

    _ = lc.luaL_error(L, "unknown component: %s", lc.luaL_checklstring(L, 2, null));
    return 0;
}

fn luaGet(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const entity = entityFromLua(self, L, 1);
    const name = componentName(L, 2);

    inline for (components.all) |T| {
        if (std.mem.eql(u8, name, lua.nameOf(T))) {
            if (comptime lua.isTag(T)) {
                lc.lua_pushboolean(L, if (self.registry.has(T, entity)) 1 else 0);
                return 1;
            } else if (comptime @hasDecl(T, "Lua")) {
                if (self.registry.tryGet(T, entity)) |val| {
                    return T.Lua.toLua(val.*, L);
                }
                return 0;
            }
        }
    }

    _ = lc.luaL_error(L, "unknown component: %s", lc.luaL_checklstring(L, 2, null));
    return 0;
}

fn luaRemove(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const entity = entityFromLua(self, L, 1);
    const name = componentName(L, 2);

    inline for (components.all) |T| {
        if (std.mem.eql(u8, name, lua.nameOf(T))) {
            self.registry.remove(T, entity);
            return 0;
        }
    }

    _ = lc.luaL_error(L, "unknown component: %s", lc.luaL_checklstring(L, 2, null));
    return 0;
}

fn luaQuery(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const nargs = lc.lua_gettop(L);
    if (nargs == 0) {
        _ = lc.luaL_error(L, "query requires at least one component name");
        return 0;
    }

    var entries: [16]QueryEntry = undefined;
    const count: usize = @intCast(nargs);
    if (count > 16) {
        _ = lc.luaL_error(L, "query supports at most 16 components");
        return 0;
    }

    for (0..count) |i| {
        const name = std.mem.span(lc.luaL_checklstring(L, @intCast(i + 1), null));
        entries[i] = findQueryEntry(name) orelse {
            _ = lc.luaL_error(L, "unknown component: %s", lc.luaL_checklstring(L, @intCast(i + 1), null));
            return 0;
        };
    }

    // Sort entries by name so query("a","b") and query("b","a") hash identically
    std.mem.sort(QueryEntry, entries[0..count], {}, struct {
        fn lessThan(_: void, a: QueryEntry, b: QueryEntry) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);

    const hash = queryHash(&entries, count);

    if (self.findCachedQuery(hash)) |idx| {
        lc.lua_rawgeti(L, lc.LUA_REGISTRYINDEX, self.query_cache[idx].lua_ref);
        return 1;
    }

    self.buildQueryTable(L, &entries, count);

    lc.lua_pushvalue(L, -1);
    const slot = self.findCacheSlot(hash);
    if (self.query_cache[slot].lua_ref != lc.LUA_NOREF) {
        lc.luaL_unref(L, lc.LUA_REGISTRYINDEX, self.query_cache[slot].lua_ref);
    }
    self.query_cache[slot] = .{
        .lua_ref = lc.luaL_ref(L, lc.LUA_REGISTRYINDEX),
        .frame = self.current_frame,
        .hash = hash,
    };

    return 1;
}

fn luaRef(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const entity = entityFromLua(self, L, 1);
    const entity_id: u32 = @bitCast(entity);
    const name = componentName(L, 2);

    inline for (components.all, 0..) |T, i| {
        if (std.mem.eql(u8, name, lua.nameOf(T))) {
            if (!self.registry.has(T, entity)) {
                _ = lc.luaL_error(L, "entity %d has no component '%s'", @as(c_int, @intCast(entity_id)), lc.luaL_checklstring(L, 2, null));
                return 0;
            }

            const ptr: *ComponentRef = @ptrCast(@alignCast(lc.lua_newuserdata(L, @sizeOf(ComponentRef))));
            ptr.* = .{ .entity_id = entity_id, .type_tag = @intCast(i) };
            lc.luaL_getmetatable(L, ref_metatable_name);
            _ = lc.lua_setmetatable(L, -2);
            return 1;
        }
    }

    _ = lc.luaL_error(L, "unknown component: %s", lc.luaL_checklstring(L, 2, null));
    return 0;
}

fn refIndex(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const ptr: *const ComponentRef = @ptrCast(@alignCast(lc.lua_touserdata(L, 1) orelse return 0));
    const field_name = std.mem.span(lc.luaL_checklstring(L, 2, null));
    const entity: ecs.Entity = @bitCast(ptr.entity_id);

    if (!self.registry.valid(entity)) {
        _ = lc.luaL_error(L, "stale ref: entity %d has been destroyed", @as(c_int, @intCast(ptr.entity_id)));
        return 0;
    }

    inline for (components.all, 0..) |T, i| {
        if (ptr.type_tag == i) {
            if (comptime lua.isTag(T)) {
                lc.lua_pushboolean(L, if (self.registry.has(T, entity)) 1 else 0);
                return 1;
            } else if (self.registry.tryGet(T, entity)) |val| {
                inline for (std.meta.fields(T)) |field| {
                    if (std.mem.eql(u8, field_name, field.name)) {
                        const fval = @field(val.*, field.name);
                        if (comptime field.type == f32) {
                            lc.lua_pushnumber(L, fval);
                        } else if (comptime field.type == u32) {
                            lc.lua_pushinteger(L, @intCast(fval));
                        }
                        return 1;
                    }
                }
                _ = lc.luaL_error(L, "no field '%s' on component", lc.luaL_checklstring(L, 2, null));
                return 0;
            }
            return 0;
        }
    }
    return 0;
}

fn refNewIndex(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const ptr: *const ComponentRef = @ptrCast(@alignCast(lc.lua_touserdata(L, 1) orelse return 0));
    const field_name = std.mem.span(lc.luaL_checklstring(L, 2, null));
    const entity: ecs.Entity = @bitCast(ptr.entity_id);

    if (!self.registry.valid(entity)) {
        _ = lc.luaL_error(L, "stale ref: entity %d has been destroyed", @as(c_int, @intCast(ptr.entity_id)));
        return 0;
    }

    inline for (components.all, 0..) |T, i| {
        if (ptr.type_tag == i) {
            if (comptime !lua.isTag(T)) {
                if (self.registry.tryGet(T, entity)) |comp| {
                    inline for (std.meta.fields(T)) |field| {
                        if (std.mem.eql(u8, field_name, field.name)) {
                            if (comptime field.type == f32) {
                                @field(comp, field.name) = @floatCast(lc.luaL_checknumber(L, 3));
                            } else if (comptime field.type == u32) {
                                @field(comp, field.name) = @intCast(lc.luaL_checkinteger(L, 3));
                            }
                            return 0;
                        }
                    }
                    _ = lc.luaL_error(L, "no field '%s' on component", lc.luaL_checklstring(L, 2, null));
                }
            }
            return 0;
        }
    }
    return 0;
}

fn luaSystemRegister(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    _ = lc.luaL_checklstring(L, 1, null);
    lc.luaL_checktype(L, 2, lc.LUA_TFUNCTION);

    lc.lua_pushvalue(L, 2);
    const ref = lc.luaL_ref(L, lc.LUA_REGISTRYINDEX);

    if (self.lua_system_count >= max_lua_systems) {
        _ = lc.luaL_error(L, "too many Lua systems (max 64)");
        return 0;
    }

    self.lua_system_refs[self.lua_system_count] = ref;
    self.lua_system_count += 1;
    return 0;
}
