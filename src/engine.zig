// engine.zig — Lunatic engine core. Lifecycle, registries, and public API.

const std = @import("std");
const builtin = @import("builtin");
const math3d = @import("math3d.zig");
const components = @import("components.zig");
const ecs = @import("zig-ecs");
const geometry = @import("geometry.zig");
const renderer = @import("renderer.zig");
const lua_api = @import("lua_api.zig");

const lua = @import("lua.zig");
const lc = lua.c;
pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

const Vertex = geometry.Vertex;

// ============================================================
// Types (pub for use by renderer and lua_api)
// ============================================================

pub const MeshData = struct {
    vertex_buffer: *c.SDL_GPUBuffer,
    vertex_count: u32,
    index_buffer: ?*c.SDL_GPUBuffer = null,
    index_count: u32 = 0,
};

pub const MaterialData = struct {
    albedo: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
};

pub const max_meshes = 64;
pub const max_materials = 64;
pub const max_lua_systems = 64;

// ============================================================
// Config
// ============================================================

pub const SampleCount = enum(u32) {
    @"1" = c.SDL_GPU_SAMPLECOUNT_1,
    @"2" = c.SDL_GPU_SAMPLECOUNT_2,
    @"4" = c.SDL_GPU_SAMPLECOUNT_4,
    @"8" = c.SDL_GPU_SAMPLECOUNT_8,

    pub fn isMultisample(self: SampleCount) bool {
        return self != .@"1";
    }

    pub fn toRaw(self: SampleCount) c.SDL_GPUSampleCount {
        return @intFromEnum(self);
    }
};

pub const Config = struct {
    title: [*:0]const u8 = "lunatic",
    width: u32 = 800,
    height: u32 = 600,
    headless: bool = false,
    msaa: SampleCount = .@"4",
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
    msaa_color_texture: ?*c.SDL_GPUTexture = null,
    swapchain_format: c.SDL_GPUTextureFormat = c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM,
    sample_count: SampleCount = .@"1",
    rt_w: u32 = 0,
    rt_h: u32 = 0,

    // Scene
    clear_color: [4]f32 = .{ 0.08, 0.08, 0.12, 1.0 },
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

    // Material registry
    material_registry: [max_materials]?MaterialData = .{null} ** max_materials,
    material_names: [max_materials]?[*:0]const u8 = .{null} ** max_materials,
    material_count: u32 = 0,

    // Draw sorting scratch buffer
    draw_list: [renderer.max_renderables]renderer.DrawEntry = undefined,

    // Query cache
    current_frame: u64 = 0,
    query_cache: [lua_api.max_cached_queries]lua_api.QueryCacheEntry = .{lua_api.QueryCacheEntry{}} ** lua_api.max_cached_queries,

    // Lua
    lua_state: ?*lc.lua_State = null,
    lua_system_refs: [max_lua_systems]c_int = .{0} ** max_lua_systems,
    lua_system_disabled: [max_lua_systems]bool = .{false} ** max_lua_systems,
    lua_system_count: u32 = 0,

    // State
    headless: bool = false,

    // ---- Lifecycle ----

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
        lua_api.registerLuaApi(self);
        _ = lc.luaL_dostring(L, "package.path = 'game/?.lua;' .. package.path");

        if (!config.headless) {
            try self.initGpu(config);
            lua_api.publishHandlesToLua(self);
        }
    }

    pub fn deinit(self: *Engine) void {
        if (self.lua_state) |L| lc.lua_close(L);

        if (self.gpu_device) |device| {
            for (0..self.mesh_count) |i| {
                if (self.mesh_registry[i]) |mesh| {
                    c.SDL_ReleaseGPUBuffer(device, mesh.vertex_buffer);
                    if (mesh.index_buffer) |ib| c.SDL_ReleaseGPUBuffer(device, ib);
                }
            }
            if (self.msaa_color_texture) |mt| c.SDL_ReleaseGPUTexture(device, mt);
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
            renderer.renderSystem(self, device);
        }
    }

    // ---- GPU init ----

    fn initGpu(self: *Engine, config: Config) !void {
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
            std.debug.print("SDL_Init failed: {s}\n", .{c.SDL_GetError()});
            return error.SDLInitFailed;
        }

        self.gpu_device = c.SDL_CreateGPUDevice(c.SDL_GPU_SHADERFORMAT_SPIRV | c.SDL_GPU_SHADERFORMAT_MSL, true, null);
        if (self.gpu_device == null) {
            std.debug.print("SDL_CreateGPUDevice failed: {s}\n", .{c.SDL_GetError()});
            return error.GPUDeviceFailed;
        }

        self.sdl_window = c.SDL_CreateWindow(config.title, @intCast(config.width), @intCast(config.height), c.SDL_WINDOW_RESIZABLE);
        if (self.sdl_window == null) {
            std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
            return error.SDLWindowFailed;
        }

        if (!c.SDL_ClaimWindowForGPUDevice(self.gpu_device.?, self.sdl_window)) {
            std.debug.print("SDL_ClaimWindowForGPUDevice failed: {s}\n", .{c.SDL_GetError()});
            return error.ClaimWindowFailed;
        }

        // Pipeline + render targets
        try renderer.initPipeline(self, config);

        // Built-in meshes
        const allocator = std.heap.c_allocator;

        const cube_mesh = try geometry.cube(allocator);
        defer allocator.free(cube_mesh.vertices);
        defer allocator.free(cube_mesh.indices);
        _ = try self.createMesh("cube", cube_mesh.vertices, cube_mesh.indices);

        const sphere_mesh = try geometry.sphere(allocator, 32, 16);
        defer allocator.free(sphere_mesh.vertices);
        defer allocator.free(sphere_mesh.indices);
        _ = try self.createMesh("sphere", sphere_mesh.vertices, sphere_mesh.indices);

        // Built-in materials
        _ = try self.createNamedMaterial("default", .{});
    }

    // ---- Mesh API ----

    pub fn createMesh(self: *Engine, name: ?[*:0]const u8, vertices: []const Vertex, indices: ?[]const u16) !u32 {
        if (self.mesh_count >= max_meshes) return error.TooManyMeshes;
        const device = self.gpu_device orelse return error.NotInitialized;
        const vbuf = uploadGPUBuffer(device, std.mem.sliceAsBytes(vertices), c.SDL_GPU_BUFFERUSAGE_VERTEX) orelse return error.BufferFailed;

        var ibuf: ?*c.SDL_GPUBuffer = null;
        var icount: u32 = 0;
        if (indices) |idx| {
            ibuf = uploadGPUBuffer(device, std.mem.sliceAsBytes(idx), c.SDL_GPU_BUFFERUSAGE_INDEX) orelse {
                c.SDL_ReleaseGPUBuffer(device, vbuf);
                return error.BufferFailed;
            };
            icount = @intCast(idx.len);
        }

        const id = self.mesh_count;
        self.mesh_registry[id] = .{
            .vertex_buffer = vbuf,
            .vertex_count = @intCast(vertices.len),
            .index_buffer = ibuf,
            .index_count = icount,
        };
        self.mesh_names[id] = name;
        self.mesh_count += 1;
        return id;
    }

    pub fn createCubeMesh(self: *Engine) !u32 {
        const allocator = std.heap.c_allocator;
        const mesh = try geometry.cube(allocator);
        defer allocator.free(mesh.vertices);
        defer allocator.free(mesh.indices);
        return self.createMesh(null, mesh.vertices, mesh.indices);
    }

    pub fn createSphereMesh(self: *Engine, segments: u32, rings: u32) !u32 {
        const allocator = std.heap.c_allocator;
        const mesh = try geometry.sphere(allocator, segments, rings);
        defer allocator.free(mesh.vertices);
        defer allocator.free(mesh.indices);
        return self.createMesh(null, mesh.vertices, mesh.indices);
    }

    pub fn findMesh(self: *Engine, name: [*:0]const u8) ?u32 {
        const needle = std.mem.span(name);
        for (0..self.mesh_count) |i| {
            if (self.mesh_names[i]) |n| {
                if (std.mem.eql(u8, std.mem.span(n), needle)) return @intCast(i);
            }
        }
        return null;
    }

    // ---- Material API ----

    pub fn createMaterial(self: *Engine, data: MaterialData) !u32 {
        return self.createNamedMaterial(null, data);
    }

    pub fn createNamedMaterial(self: *Engine, name: ?[*:0]const u8, data: MaterialData) !u32 {
        if (self.material_count >= max_materials) return error.TooManyMaterials;
        const id = self.material_count;
        self.material_registry[id] = data;
        self.material_names[id] = name;
        self.material_count += 1;
        return id;
    }

    pub fn findMaterial(self: *Engine, name: [*:0]const u8) ?u32 {
        const needle = std.mem.span(name);
        for (0..self.material_count) |i| {
            if (self.material_names[i]) |n| {
                if (std.mem.eql(u8, std.mem.span(n), needle)) return @intCast(i);
            }
        }
        return null;
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
        if (self.lua_state) |L| {
            for (0..self.lua_system_count) |i| {
                lc.luaL_unref(L, lc.LUA_REGISTRYINDEX, self.lua_system_refs[i]);
            }
        }
        self.lua_system_count = 0;
        self.lua_system_refs = .{0} ** max_lua_systems;
        self.lua_system_disabled = .{false} ** max_lua_systems;
    }
};

// ============================================================
// GPU helpers
// ============================================================

fn uploadGPUBuffer(device: *c.SDL_GPUDevice, data: []const u8, usage: c.SDL_GPUBufferUsageFlags) ?*c.SDL_GPUBuffer {
    const data_size: u32 = @intCast(data.len);
    const buf = c.SDL_CreateGPUBuffer(device, &c.SDL_GPUBufferCreateInfo{
        .usage = usage,
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
