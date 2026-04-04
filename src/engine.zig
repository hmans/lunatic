// engine.zig — Lunatic engine core. Import this as a library.

const std = @import("std");
const builtin = @import("builtin");
const math3d = @import("math3d.zig");
const components = @import("components.zig");
const ecs = @import("zig-ecs");
const Mat4 = math3d.Mat4;
const Vec3 = math3d.Vec3;

const geometry = @import("geometry.zig");
const lua = @import("lua.zig");
const lc = lua.c;
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

// Re-export component types
const Position = components.Position;
const Rotation = components.Rotation;
const MeshHandle = components.MeshHandle;
const MaterialHandle = components.MaterialHandle;
const Camera = components.Camera;
const DirectionalLight = components.DirectionalLight;
const Spin = components.Spin;

const Vertex = geometry.Vertex;

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
    fog_color: [4]f32, // .xyz = color, .w = fog_enabled (1.0 or 0.0)
    fog_params: [4]f32, // .x = fog_start, .y = fog_end
    ambient: [4]f32,
};

const MaterialUniforms = extern struct {
    albedo: [4]f32,
};

// ============================================================
// Constants
// ============================================================

const MeshData = struct {
    buffer: *c.SDL_GPUBuffer,
    vertex_count: u32,
};

const MaterialData = struct {
    albedo: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
};

const max_meshes = 64;
const max_materials = 64;
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

fn createDepthTexture(device: *c.SDL_GPUDevice, w: u32, h: u32, sample_count: SampleCount) ?*c.SDL_GPUTexture {
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

fn createMsaaColorTexture(device: *c.SDL_GPUDevice, format: c.SDL_GPUTextureFormat, w: u32, h: u32, sample_count: SampleCount) ?*c.SDL_GPUTexture {
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
// Config
// ============================================================

pub const SampleCount = enum(u32) {
    @"1" = c.SDL_GPU_SAMPLECOUNT_1,
    @"2" = c.SDL_GPU_SAMPLECOUNT_2,
    @"4" = c.SDL_GPU_SAMPLECOUNT_4,
    @"8" = c.SDL_GPU_SAMPLECOUNT_8,

    fn isMultisample(self: SampleCount) bool {
        return self != .@"1";
    }

    fn toRaw(self: SampleCount) c.SDL_GPUSampleCount {
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
            self.publishHandlesToLua();
        }
    }

    pub fn deinit(self: *Engine) void {
        if (self.lua_state) |L| lc.lua_close(L);

        if (self.gpu_device) |device| {
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
            self.renderSystem(device);
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

        // Pipeline
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

        // Built-in meshes
        const allocator = std.heap.c_allocator;

        const cube_verts = try geometry.cube(allocator);
        defer allocator.free(cube_verts);
        _ = try self.createMesh("cube", cube_verts);

        const sphere_verts = try geometry.sphere(allocator, 32, 16);
        defer allocator.free(sphere_verts);
        _ = try self.createMesh("sphere", sphere_verts);

        // Built-in materials
        _ = self.createNamedMaterial("default", .{});

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

    // ---- Mesh API ----

    pub fn createMesh(self: *Engine, name: ?[*:0]const u8, vertices: []const Vertex) !u32 {
        const device = self.gpu_device orelse return error.NotInitialized;
        const buf = uploadVertexData(device, std.mem.sliceAsBytes(vertices)) orelse return error.BufferFailed;
        const id = self.mesh_count;
        self.mesh_registry[id] = .{ .buffer = buf, .vertex_count = @intCast(vertices.len) };
        self.mesh_names[id] = name;
        self.mesh_count += 1;
        return id;
    }

    pub fn createCubeMesh(self: *Engine) !u32 {
        const allocator = std.heap.c_allocator;
        const verts = try geometry.cube(allocator);
        defer allocator.free(verts);
        return self.createMesh(null, verts);
    }

    pub fn createSphereMesh(self: *Engine, segments: u32, rings: u32) !u32 {
        const allocator = std.heap.c_allocator;
        const verts = try geometry.sphere(allocator, segments, rings);
        defer allocator.free(verts);
        return self.createMesh(null, verts);
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

    // ---- Material API ----

    pub fn createMaterial(self: *Engine, data: MaterialData) u32 {
        return self.createNamedMaterial(null, data);
    }

    pub fn createNamedMaterial(self: *Engine, name: ?[*:0]const u8, data: MaterialData) u32 {
        const id = self.material_count;
        self.material_registry[id] = data;
        self.material_names[id] = name;
        self.material_count += 1;
        return id;
    }

    fn findMaterial(self: *Engine, name: [*:0]const u8) ?u32 {
        const needle = std.mem.span(name);
        for (0..self.material_count) |i| {
            if (self.material_names[i]) |n| {
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

        const color_target = if (self.sample_count.isMultisample()) c.SDL_GPUColorTargetInfo{
            .texture = self.msaa_color_texture,
            .mip_level = 0,
            .layer_or_depth_plane = 0,
            .clear_color = .{ .r = self.clear_color[0], .g = self.clear_color[1], .b = self.clear_color[2], .a = self.clear_color[3] },
            .load_op = c.SDL_GPU_LOADOP_CLEAR,
            .store_op = c.SDL_GPU_STOREOP_RESOLVE,
            .resolve_texture = swapchain_tex,
            .resolve_mip_level = 0,
            .resolve_layer = 0,
            .cycle = true,
            .cycle_resolve_texture = false,
            .padding1 = 0,
            .padding2 = 0,
        } else c.SDL_GPUColorTargetInfo{
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

        // Render once per camera entity
        var cam_view = self.registry.view(.{ Position, Rotation, Camera }, .{});
        var cam_iter = cam_view.entityIterator();
        while (cam_iter.next()) |cam_entity| {
            const cam_pos = cam_view.getConst(Position, cam_entity);
            const cam_rot = cam_view.getConst(Rotation, cam_entity);
            const cam = cam_view.getConst(Camera, cam_entity);

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
            const view = Mat4.viewFromTransform(cam_pos.x, cam_pos.y, cam_pos.z, cam_rot.x, cam_rot.y, cam_rot.z);
            const vp = Mat4.mul(proj, view);

            const scene_uniforms = SceneUniforms{
                .light_dir = light_dir,
                .camera_pos = .{ cam_pos.x, cam_pos.y, cam_pos.z, 0.0 },
                .fog_color = .{ self.fog_color[0], self.fog_color[1], self.fog_color[2], if (self.fog_enabled) 1.0 else 0.0 },
                .fog_params = .{ self.fog_start, self.fog_end, 0.0, 0.0 },
                .ambient = self.ambient_color,
            };
            c.SDL_PushGPUFragmentUniformData(cmd, 0, &scene_uniforms, @sizeOf(SceneUniforms));

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

                // Per-entity material
                const mat_uniforms = if (self.registry.tryGet(MaterialHandle, entity)) |mat_handle|
                    if (self.material_registry[mat_handle.id]) |mat|
                        MaterialUniforms{ .albedo = mat.albedo }
                    else
                        default_material
                else
                    default_material;

                const rotation = Mat4.mul(Mat4.mul(Mat4.rotateZ(rot.z), Mat4.rotateY(rot.y)), Mat4.rotateX(rot.x));
                const model = Mat4.mul(Mat4.translate(pos.x, pos.y, pos.z), rotation);
                const mvp = Mat4.mul(vp, model);

                const vert_uniforms = VertexUniforms{ .mvp = mvp.m, .model = model.m };
                c.SDL_PushGPUVertexUniformData(cmd, 0, &vert_uniforms, @sizeOf(VertexUniforms));
                c.SDL_PushGPUFragmentUniformData(cmd, 1, &mat_uniforms, @sizeOf(MaterialUniforms));
                c.SDL_DrawGPUPrimitives(render_pass, mesh.vertex_count, 1, 0, 0);
            }
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
            .{ "set_clear_color", &luaSetClearColor },
            .{ "set_fog", &luaSetFog },
            .{ "set_ambient", &luaSetAmbient },
            .{ "spawn", &luaSpawn },
            .{ "destroy", &luaDestroy },
            .{ "add", &luaAdd },
            .{ "get", &luaGet },
            .{ "remove", &luaRemove },
            .{ "query", &luaQuery },
            .{ "ref", &luaRef },
            .{ "create_material", &luaCreateMaterial },
            .{ "create_cube_mesh", &luaCreateCubeMesh },
            .{ "create_sphere_mesh", &luaCreateSphereMesh },
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

    /// Populate lunatic.mesh.* and lunatic.material.* tables with numeric handles.
    fn publishHandlesToLua(self: *Engine) void {
        const L = self.lua_state orelse return;

        lc.lua_getglobal(L, "lunatic");

        // lunatic.mesh = { cube = 0, ... }
        lc.lua_newtable(L);
        for (0..self.mesh_count) |i| {
            if (self.mesh_names[i]) |name| {
                lc.lua_pushinteger(L, @intCast(i));
                lc.lua_setfield(L, -2, name);
            }
        }
        lc.lua_setfield(L, -2, "mesh");

        // lunatic.material = { default = 0, ... }
        lc.lua_newtable(L);
        for (0..self.material_count) |i| {
            if (self.material_names[i]) |name| {
                lc.lua_pushinteger(L, @intCast(i));
                lc.lua_setfield(L, -2, name);
            }
        }
        lc.lua_setfield(L, -2, "material");

        lc.lua_pop(L, 1); // pop lunatic table
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

const HandleKind = enum { mesh, material };

/// Accept either a numeric handle (fast path) or a string name (legacy/convenience).
fn resolveHandle(self: *Engine, L: ?*lc.lua_State, idx: c_int, kind: HandleKind) u32 {
    if (lc.lua_type(L, idx) == lc.LUA_TNUMBER) {
        return @intCast(lc.lua_tointeger(L, idx));
    }
    const name = lc.luaL_checklstring(L, idx, null);
    const id = switch (kind) {
        .mesh => self.findMesh(name),
        .material => self.findMaterial(name),
    };
    if (id) |found| return found;
    const label = switch (kind) {
        .mesh => "unknown mesh: %s",
        .material => "unknown material: %s",
    };
    _ = lc.luaL_error(L, label, name);
    unreachable;
}

fn luaKeyDown(L: ?*lc.lua_State) callconv(.c) c_int {
    _ = getEngine(L); // validate upvalue; key_down doesn't need engine state
    const name = lc.luaL_checklstring(L, 1, null);
    const scancode = c.SDL_GetScancodeFromName(name);
    const state = c.SDL_GetKeyboardState(null);
    lc.lua_pushboolean(L, if (state[scancode]) 1 else 0);
    return 1;
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

fn luaSetAmbient(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    self.ambient_color[0] = @floatCast(lc.luaL_checknumber(L, 1));
    self.ambient_color[1] = @floatCast(lc.luaL_checknumber(L, 2));
    self.ambient_color[2] = @floatCast(lc.luaL_checknumber(L, 3));
    return 0;
}

fn luaCreateCubeMesh(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const id = self.createCubeMesh() catch {
        _ = lc.luaL_error(L, "failed to create cube mesh");
        unreachable;
    };
    lc.lua_pushinteger(L, @intCast(id));
    return 1;
}

fn luaCreateSphereMesh(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const segments: u32 = if (lc.lua_type(L, 1) == lc.LUA_TTABLE) blk: {
        lc.lua_getfield(L, 1, "segments");
        const s: u32 = @intCast(lc.luaL_optinteger(L, -1, 32));
        lc.lua_pop(L, 1);
        break :blk s;
    } else 32;
    const rings: u32 = if (lc.lua_type(L, 1) == lc.LUA_TTABLE) blk: {
        lc.lua_getfield(L, 1, "rings");
        const r: u32 = @intCast(lc.luaL_optinteger(L, -1, 16));
        lc.lua_pop(L, 1);
        break :blk r;
    } else 16;
    const id = self.createSphereMesh(segments, rings) catch {
        _ = lc.luaL_error(L, "failed to create sphere mesh");
        unreachable;
    };
    lc.lua_pushinteger(L, @intCast(id));
    return 1;
}

fn luaCreateMaterial(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    lc.luaL_checktype(L, 1, lc.LUA_TTABLE);

    var data = MaterialData{};

    // Read "albedo" field: { r, g, b }
    lc.lua_getfield(L, 1, "albedo");
    if (lc.lua_type(L, -1) == lc.LUA_TTABLE) {
        lc.lua_rawgeti(L, -1, 1);
        data.albedo[0] = @floatCast(lc.luaL_optnumber(L, -1, 1.0));
        lc.lua_pop(L, 1);
        lc.lua_rawgeti(L, -1, 2);
        data.albedo[1] = @floatCast(lc.luaL_optnumber(L, -1, 1.0));
        lc.lua_pop(L, 1);
        lc.lua_rawgeti(L, -1, 3);
        data.albedo[2] = @floatCast(lc.luaL_optnumber(L, -1, 1.0));
        lc.lua_pop(L, 1);
    }
    lc.lua_pop(L, 1); // pop albedo field

    const id = self.createMaterial(data);
    lc.lua_pushinteger(L, @intCast(id));
    return 1;
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
        const mesh_id = resolveHandle(self, L, 3, .mesh);
        self.registry.addOrReplace(entity, MeshHandle{ .id = mesh_id });
        return 0;
    }

    if (std.mem.eql(u8, name, lua.nameOf(MaterialHandle))) {
        const mat_id = resolveHandle(self, L, 3, .material);
        self.registry.addOrReplace(entity, MaterialHandle{ .id = mat_id });
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
