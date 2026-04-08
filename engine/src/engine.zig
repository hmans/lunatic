// engine.zig — Lunatic engine core. Lifecycle, registries, and public API.

const std = @import("std");
const builtin = @import("builtin");
const math3d = @import("math3d");
const Mat4 = math3d.Mat4;
pub const ecs = @import("zflecs");
const geometry = @import("geometry");
const renderer = @import("renderer");
pub const postprocess = @import("postprocess");
pub const physics = @import("physics");
pub const gltf = @import("gltf");
pub const debug_server = @import("debug_server");
pub const lua_systems = @import("lua_systems");

pub const core_components = @import("core_components");
pub const components = @import("components");
pub const HandleKind = enum { mesh, material };
pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("cimgui.h");
    @cInclude("cimgui_impl_sdlgpu3.h");
});
const stbi = @cImport({
    @cInclude("stb_image.h");
});
const stbiw = @cImport({
    @cInclude("stb_image_write.h");
});

const Vertex = geometry.Vertex;

// ============================================================
// Types (pub for use by renderer and other modules)
// ============================================================

pub const MeshData = struct {
    vertex_count: u32,
    index_count: u32 = 0,
    /// Offset (in vertices) into the merged vertex buffer.
    base_vertex: u32 = 0,
    /// Offset (in indices) into the merged index buffer.
    first_index: u32 = 0,
    /// True if this mesh has index data in the merged index buffer.
    indexed: bool = false,
};

/// Maximum total vertices across all meshes in the merged vertex buffer.
/// 1M vertices * 48 bytes = 48 MB — generous for game-scale geometry.
pub const max_merged_vertices: u32 = 1024 * 1024;
/// Maximum total indices across all meshes in the merged index buffer.
/// 4M indices * 4 bytes = 16 MB.
pub const max_merged_indices: u32 = 4 * 1024 * 1024;

pub const TextureData = struct {
    texture: *c.SDL_GPUTexture,
    sampler: *c.SDL_GPUSampler,
    width: u32,
    height: u32,
};

pub const MaterialData = struct {
    albedo: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    metallic: f32 = 0.0,
    roughness: f32 = 0.5,
    emissive: [3]f32 = .{ 0, 0, 0 },
    base_color_texture: ?u32 = null,
    metallic_roughness_texture: ?u32 = null,
    normal_texture: ?u32 = null,
    emissive_texture: ?u32 = null,
    occlusion_texture: ?u32 = null,
};

pub const max_meshes = 64;
pub const max_materials = 64;
pub const max_textures = 64;
pub const ZigSystemFn = *const fn (*Engine, f32) void;

// ============================================================
// Asset store — groups mesh, material, and texture registries
// ============================================================

pub const AssetStore = struct {
    mesh_registry: [max_meshes]?MeshData = .{null} ** max_meshes,
    mesh_names: [max_meshes]?[*:0]const u8 = .{null} ** max_meshes,
    mesh_count: u32 = 0,

    material_registry: [max_materials]?MaterialData = .{null} ** max_materials,
    material_names: [max_materials]?[*:0]const u8 = .{null} ** max_materials,
    material_count: u32 = 0,

    texture_registry: [max_textures]?TextureData = .{null} ** max_textures,
    texture_count: u32 = 0,
    default_sampler: ?*c.SDL_GPUSampler = null,
    dummy_texture: ?*c.SDL_GPUTexture = null,

    /// Look up a named mesh by string. Returns the handle or null.
    pub fn findMesh(self: *const AssetStore, name: [*:0]const u8) ?u32 {
        const needle = std.mem.span(name);
        for (0..self.mesh_count) |i| {
            if (self.mesh_names[i]) |n| {
                if (std.mem.eql(u8, std.mem.span(n), needle)) return @intCast(i);
            }
        }
        return null;
    }

    /// Look up a named material by string. Returns the handle or null.
    pub fn findMaterial(self: *const AssetStore, name: [*:0]const u8) ?u32 {
        const needle = std.mem.span(name);
        for (0..self.material_count) |i| {
            if (self.material_names[i]) |n| {
                if (std.mem.eql(u8, std.mem.span(n), needle)) return @intCast(i);
            }
        }
        return null;
    }

    /// Release all GPU resources held by the asset store.
    /// Note: mesh vertex/index data lives in the merged geometry buffers
    /// (released by Engine.deinit), so only textures need cleanup here.
    pub fn deinit(self: *AssetStore, device: *c.SDL_GPUDevice) void {
        for (0..self.texture_count) |i| {
            if (self.texture_registry[i]) |tex| c.SDL_ReleaseGPUTexture(device, tex.texture);
        }
        if (self.default_sampler) |s| c.SDL_ReleaseGPUSampler(device, s);
    }
};

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
    debug_stats: bool = false,
};

// ============================================================
// Engine
// ============================================================

pub const FrameStats = struct {
    draw_calls: u32 = 0,
    entities_rendered: u32 = 0,
    visible_after_cull: u32 = 0, // entities that passed GPU culling (from readback)
    frustum_culled: u32 = 0, // entities rejected by frustum culling
    occlusion_culled: u32 = 0, // entities rejected by HiZ occlusion culling
    physics_active: u32 = 0,
    physics_total: u32 = 0,
    // Render sub-timings (raw + smoothed)
    time_prepare_us: u64 = 0,
    time_instances_us: u64 = 0,
    time_scene_us: u64 = 0,
    time_postprocess_us: u64 = 0,
    time_imgui_us: u64 = 0,
    avg_prepare: f64 = 0,
    avg_instances: f64 = 0,
    avg_scene: f64 = 0,
    avg_postprocess: f64 = 0,
    avg_imgui: f64 = 0,

    // Accumulate samples, snapshot averages twice per second
    acc_prepare: u64 = 0,
    acc_instances: u64 = 0,
    acc_scene: u64 = 0,
    acc_postprocess: u64 = 0,
    acc_imgui: u64 = 0,
    acc_frames: u32 = 0,
    snapshot_frames: u32 = 1, // frames in last snapshot (for system avg)

    pub fn accumulate(self: *FrameStats) void {
        self.acc_prepare += self.time_prepare_us;
        self.acc_instances += self.time_instances_us;
        self.acc_scene += self.time_scene_us;
        self.acc_postprocess += self.time_postprocess_us;
        self.acc_imgui += self.time_imgui_us;
        self.acc_frames += 1;

        // Snapshot every ~0.5s (30 frames at 60fps)
        if (self.acc_frames >= 30) {
            self.snapshot_frames = self.acc_frames;
            const n: f64 = @floatFromInt(self.acc_frames);
            self.avg_prepare = @as(f64, @floatFromInt(self.acc_prepare)) / n;
            self.avg_instances = @as(f64, @floatFromInt(self.acc_instances)) / n;
            self.avg_scene = @as(f64, @floatFromInt(self.acc_scene)) / n;
            self.avg_postprocess = @as(f64, @floatFromInt(self.acc_postprocess)) / n;
            self.avg_imgui = @as(f64, @floatFromInt(self.acc_imgui)) / n;
            self.acc_prepare = 0;
            self.acc_instances = 0;
            self.acc_scene = 0;
            self.acc_postprocess = 0;
            self.acc_imgui = 0;
            self.acc_frames = 0;
        }
    }
};

// ============================================================
// Flecs query helpers
// ============================================================

/// Flecs meta type IDs for f32 and u32, resolved at runtime from C externs.
const flecs_f32_id = @extern(*const ecs.entity_t, .{ .name = "FLECS_IDecs_f32_tID_" });
const flecs_u32_id = @extern(*const ecs.entity_t, .{ .name = "FLECS_IDecs_u32_tID_" });

/// Register struct metadata with flecs so the Explorer can display and
/// edit component fields. Maps Zig struct fields to flecs member descriptors.
/// Only handles f32 and u32 fields.
fn registerStructMeta(world: *ecs.world_t, comptime T: type) void {
    const fields = std.meta.fields(T);
    var desc = std.mem.zeroes(ecs.struct_desc_t);
    desc.entity = ecs.id(T);
    inline for (fields, 0..) |field, i| {
        if (i >= ecs.ECS_MEMBER_DESC_CACHE_SIZE) break;
        desc.members[i].name = @ptrCast(field.name.ptr);
        desc.members[i].type = if (field.type == f32)
            flecs_f32_id.*
        else if (field.type == u32)
            flecs_u32_id.*
        else
            0;
    }
    _ = ecs.struct_init(world, &desc);
}

// ============================================================
// Flecs system callbacks — proper query-driven systems
// ============================================================

/// Age system: increments Age.seconds. Fully parallelizable, no defer needed.
fn ageSystemFlecs(it: *ecs.iter_t, ages: []core_components.Age) void {
    for (ages) |*age| {
        age.seconds += it.delta_time;
    }
}

/// Fly camera system: reads FlyCamera config, writes Position + Rotation.
/// Uses iter to access entities for per-entity component access since we
/// need both mutable Position/Rotation and const FlyCamera simultaneously.
fn flyCameraSystemFlecs(it: *ecs.iter_t, positions: []core_components.Position, rotations: []core_components.Rotation, fly_cams: []const core_components.FlyCamera) void {
    const engine: *Engine = @ptrCast(@alignCast(it.ctx));
    const io = c.igGetIO();
    if (io != null and io.*.WantCaptureMouse) return;

    var dx: f32 = 0;
    var dy: f32 = 0;
    const buttons = c.SDL_GetRelativeMouseState(&dx, &dy);
    const rmb_held = (buttons & c.SDL_BUTTON_RMASK) != 0;

    if (rmb_held) {
        _ = c.SDL_HideCursor();
    } else {
        _ = c.SDL_ShowCursor();
    }

    if (!rmb_held) return;

    for (positions, rotations, fly_cams) |*pos, *rot, fly| {
        // Mouse look
        rot.y += dx * fly.sensitivity;
        rot.x += dy * fly.sensitivity;
        rot.x = std.math.clamp(rot.x, -89, 89);

        // Camera axes from pitch/yaw
        const deg2rad = std.math.pi / 180.0;
        const pitch = rot.x * deg2rad;
        const yaw = rot.y * deg2rad;
        const cp = @cos(pitch);
        const sp = @sin(pitch);
        const cy = @cos(yaw);
        const sy = @sin(yaw);

        const fx = sy * cp;
        const fy = -sp;
        const fz = -cy * cp;
        const rx = cy;
        const ry: f32 = 0;
        const rz = sy;

        const speed: f32 = if (engine.isKeyDown(c.SDL_SCANCODE_LSHIFT)) fly.fast_speed else fly.speed;
        const dt = it.delta_time;
        if (engine.isKeyDown(c.SDL_SCANCODE_W)) { pos.x += fx * speed * dt; pos.y += fy * speed * dt; pos.z += fz * speed * dt; }
        if (engine.isKeyDown(c.SDL_SCANCODE_S)) { pos.x -= fx * speed * dt; pos.y -= fy * speed * dt; pos.z -= fz * speed * dt; }
        if (engine.isKeyDown(c.SDL_SCANCODE_A)) { pos.x -= rx * speed * dt; pos.y -= ry * speed * dt; pos.z -= rz * speed * dt; }
        if (engine.isKeyDown(c.SDL_SCANCODE_D)) { pos.x += rx * speed * dt; pos.y += ry * speed * dt; pos.z += rz * speed * dt; }
        if (engine.isKeyDown(c.SDL_SCANCODE_SPACE)) pos.y += speed * dt;
        if (engine.isKeyDown(c.SDL_SCANCODE_LCTRL)) pos.y -= speed * dt;
    }
}

/// C-callable flecs callback wrapper for Zig systems that need immediate mode
/// (physics, stats overlay). These systems have complex access patterns that
/// can't be expressed as simple query terms.
fn zigSystemCallback(comptime func: ZigSystemFn) ecs.iter_action_t {
    return &struct {
        fn callback(it: *ecs.iter_t) callconv(.c) void {
            const engine: *Engine = @ptrCast(@alignCast(it.ctx));
            ecs.defer_suspend(engine.world);
            func(engine, it.delta_time);
            ecs.defer_resume(engine.world);
        }
    }.callback;
}

/// Build a flecs query from slices of include/exclude component IDs.
/// Simpler than filling out query_desc_t manually each time.
pub fn queryInit(world: *ecs.world_t, includes: []const ecs.id_t, excludes: []const ecs.id_t) *ecs.query_t {
    var desc = std.mem.zeroes(ecs.query_desc_t);
    for (includes, 0..) |comp_id, i| {
        desc.terms[i].id = comp_id;
    }
    for (excludes, 0..) |comp_id, j| {
        desc.terms[includes.len + j].id = comp_id;
        desc.terms[includes.len + j].oper = .Not;
    }
    return ecs.query_init(world, &desc) catch
        std.debug.panic("Failed to create flecs query", .{});
}

pub const Engine = struct {
    // ECS (flecs world — replaces zig-ecs Registry)
    world: *ecs.world_t,

    // GPU (null when headless)
    gpu_device: ?*c.SDL_GPUDevice = null,
    sdl_window: ?*c.SDL_Window = null,
    pipeline: ?*c.SDL_GPUGraphicsPipeline = null,
    instance_buffer: ?*c.SDL_GPUBuffer = null,
    instance_transfer: ?*c.SDL_GPUTransferBuffer = null,
    instance_capacity: u32 = 0,

    // GPU-driven: compute pipeline + entity data buffers
    compute_pipeline: ?*c.SDL_GPUComputePipeline = null,
    entity_data_buffer: ?*c.SDL_GPUBuffer = null,
    entity_data_transfer: ?*c.SDL_GPUTransferBuffer = null,

    // Merged geometry buffers: all mesh vertex/index data in single GPU buffers.
    // Eliminates per-batch vertex/index buffer rebinding in draw calls.
    merged_vertex_buffer: ?*c.SDL_GPUBuffer = null,
    merged_index_buffer: ?*c.SDL_GPUBuffer = null,
    merged_vertex_offset: u32 = 0, // append cursor (in vertices)
    merged_index_offset: u32 = 0, // append cursor (in indices)

    // GPU-driven indirect draw: batch info + indirect command buffers
    batch_info_buffer: ?*c.SDL_GPUBuffer = null,
    indirect_draw_buffer: ?*c.SDL_GPUBuffer = null,
    batch_transfer: ?*c.SDL_GPUTransferBuffer = null,
    batch_descriptors: [renderer.max_batches]renderer.BatchDescriptor = undefined,
    batch_count: u32 = 0,
    depth_texture: ?*c.SDL_GPUTexture = null,
    msaa_color_texture: ?*c.SDL_GPUTexture = null,
    msaa_normal_texture: ?*c.SDL_GPUTexture = null, // MSAA resolve source for normal+roughness
    normal_roughness_texture: ?*c.SDL_GPUTexture = null, // Resolved normal+roughness (for SSR)
    swapchain_format: c.SDL_GPUTextureFormat = c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM,
    sample_count: SampleCount = .@"1",
    rt_w: u32 = 0,
    rt_h: u32 = 0,

    // Cascaded shadow maps
    shadow_atlas: ?*c.SDL_GPUTexture = null, // R32_FLOAT color target (stores depth)
    shadow_depth: ?*c.SDL_GPUTexture = null, // D32_FLOAT depth target (for z-testing)
    shadow_pipeline: ?*c.SDL_GPUGraphicsPipeline = null,
    shadow_sampler: ?*c.SDL_GPUSampler = null,

    // Scene
    clear_color: [4]f32 = .{ 0.08, 0.08, 0.12, 1.0 },
    ambient_color: [4]f32 = .{ 0.15, 0.15, 0.2, 0.0 },

    // Post-processing (bloom)
    postprocess: postprocess.PostProcessState = .{},
    physics: physics.PhysicsState = .{},

    // Fog (legacy screen-space)
    fog_enabled: bool = false,
    fog_start: f32 = 10.0,
    fog_end: f32 = 30.0,
    fog_color: [3]f32 = .{ 0.08, 0.08, 0.12 },

    // Volumetric fog (froxel-based)
    vol_fog_enabled: bool = false,
    vol_fog_density: f32 = 0.02, // base fog density
    vol_fog_height_falloff: f32 = 0.5, // exponential height falloff rate
    vol_fog_height_offset: f32 = 0.0, // world Y where fog starts
    vol_fog_anisotropy: f32 = 0.6, // Henyey-Greenstein g (>0 = forward scatter = god rays)
    vol_fog_albedo: [3]f32 = .{ 1.0, 1.0, 1.0 }, // fog color
    vol_fog_scattering: f32 = 0.05, // scattering coefficient
    vol_fog_shadow_steps: f32 = 4.0, // screen-space shadow ray march steps (1-8)
    vol_fog_shadow_softness: f32 = 3.0, // shadow penumbra width (smoothstep upper bound)
    fog_inject_pipeline: ?*c.SDL_GPUComputePipeline = null, // compute: froxel injection

    // Asset registries (meshes, materials, textures)
    assets: AssetStore = .{},

    // Draw sorting scratch buffer
    draw_list: [renderer.max_renderables]renderer.DrawEntry = undefined,

    // Persistent ECS queries (created once at init, reused every frame)
    renderable_query: ?*ecs.query_t = null, // Position, Rotation, MeshHandle + optional Scale, Material, Shadow*
    dir_light_query: ?*ecs.query_t = null, // DirectionalLight
    point_light_query: ?*ecs.query_t = null, // Position, PointLight
    spot_light_query: ?*ecs.query_t = null, // Position, SpotLight
    camera_query: ?*ecs.query_t = null, // Position, Camera

    // Draw list dirty flag — skip sort + batch rebuild when structure hasn't changed
    draw_list_dirty: bool = true,
    prev_draw_count: u32 = 0,

    // Previous frame's VP matrix and camera position, used for HiZ occlusion
    // culling reprojection. Initialized to identity/zero; occlusion culling
    // auto-disables on the first frame (HiZ contains far-plane depth).
    prev_vp: [4][4]f32 = std.mem.zeroes([4][4]f32),
    prev_camera_pos: [4]f32 = .{ 0, 0, 0, 0 },

    // Culling statistics readback: GPU writes atomic counters during the scene
    // compute dispatch, CPU reads the previous frame's data (no GPU stall).
    culling_stats_buffer: ?*c.SDL_GPUBuffer = null,
    culling_stats_transfer: ?*c.SDL_GPUTransferBuffer = null,
    culling_stats: renderer.CullingStats = .{}, // previous frame's readback data

    // Clustered lighting GPU buffers
    cluster_light_buffer: ?*c.SDL_GPUBuffer = null,
    cluster_info_buffer: ?*c.SDL_GPUBuffer = null,
    cluster_index_buffer: ?*c.SDL_GPUBuffer = null,
    cluster_transfer: ?*c.SDL_GPUTransferBuffer = null,

    // Clustered lighting CPU scratch
    cluster_lights: [renderer.max_lights]renderer.GPULight = undefined,
    cluster_light_count: u32 = 0,
    cluster_infos: [renderer.num_clusters]renderer.ClusterInfo = undefined,
    cluster_indices: [renderer.max_light_indices]u32 = undefined,
    cluster_index_count: u32 = 0,

    // Frame counter + stats
    current_frame: u64 = 0,
    stats: FrameStats = .{},

    // Debug server (HTTP API for external tools)
    dbg_server: debug_server.DebugServer = .{},

    // Lua systems (optional per-system LuaJIT VMs with hot-reload)
    lua_sys: lua_systems.LuaSystemManager = .{},

    // State
    headless: bool = false,
    debug_stats: bool = false,
    screenshot_requested: bool = false,
    screenshot_path_buf: [256]u8 = undefined,
    screenshot_path_len: u8 = 0,
    screenshot_texture: ?*c.SDL_GPUTexture = null,
    screenshot_tex_w: u32 = 0,
    screenshot_tex_h: u32 = 0,

    // ---- Lifecycle ----

    /// Initialize the engine: ECS, GPU device, pipeline, built-in resources.
    /// Must be called on a pointer-stable location (e.g. `var engine: Engine = undefined;`).
    pub fn init(self: *Engine, config: Config) !void {
        const world = ecs.init();
        self.* = Engine{
            .world = world,
            .headless = config.headless,
            .debug_stats = config.debug_stats,
        };
        errdefer _ = ecs.fini(world);

        // Register all component types with flecs (required before use),
        // then register their struct metadata for the Explorer's reflection UI.
        inline for (components.all) |T| {
            if (@sizeOf(T) == 0) {
                ecs.TAG(world, T);
            } else {
                ecs.COMPONENT(world, T);
                registerStructMeta(world, T);
            }
        }

        if (!config.headless) {
            try self.initGpu(config);

            // Enable flecs REST API for the Explorer debug UI.
            // Connect at https://www.flecs.dev/explorer to inspect entities,
            // components, and queries in real-time. Requires ecs.progress()
            // to be called each frame (done in the main loop).
            const rest_comp_id = @as(ecs.id_t, @extern(*const ecs.entity_t, .{ .name = "FLECS_IDEcsRestID_" }).*);
            const rest_val = ecs.EcsRest{ .port = 27750 };
            _ = ecs.set_id(world, rest_comp_id, rest_comp_id, @sizeOf(ecs.EcsRest), @ptrCast(&rest_val));
        }
    }

    /// Release all GPU resources and ECS storage.
    pub fn deinit(self: *Engine) void {
        self.lua_sys.deinit();
        self.dbg_server.stop();
        physics.deinitPhysics(self);

        // Skip ecs_fini in non-headless mode. The flecs REST server keeps
        // internal iterators alive between frames, and ecs_fini asserts on
        // those as "leaked". This is harmless at process exit — the OS
        // reclaims all memory. Headless mode (tests) has no REST server
        // and shuts down cleanly.
        if (self.gpu_device == null) {
            _ = ecs.fini(self.world);
        }

        if (self.gpu_device) |_| {
            c.cImGui_ImplSDLGPU3_Shutdown();
            c.cImGui_ImplSDL3_Shutdown();
            c.igDestroyContext(null);
            postprocess.deinitPostProcess(self);
            const device = self.gpu_device.?;
            self.assets.deinit(device);
            if (self.screenshot_texture) |t| c.SDL_ReleaseGPUTexture(device, t);
            if (self.msaa_color_texture) |mt| c.SDL_ReleaseGPUTexture(device, mt);
            if (self.depth_texture) |dt| c.SDL_ReleaseGPUTexture(device, dt);
            if (self.instance_buffer) |b| c.SDL_ReleaseGPUBuffer(device, b);
            if (self.instance_transfer) |t| c.SDL_ReleaseGPUTransferBuffer(device, t);
            if (self.entity_data_buffer) |b| c.SDL_ReleaseGPUBuffer(device, b);
            if (self.entity_data_transfer) |t| c.SDL_ReleaseGPUTransferBuffer(device, t);
            if (self.compute_pipeline) |p| c.SDL_ReleaseGPUComputePipeline(device, p);
            if (self.merged_vertex_buffer) |b| c.SDL_ReleaseGPUBuffer(device, b);
            if (self.merged_index_buffer) |b| c.SDL_ReleaseGPUBuffer(device, b);
            if (self.batch_info_buffer) |b| c.SDL_ReleaseGPUBuffer(device, b);
            if (self.indirect_draw_buffer) |b| c.SDL_ReleaseGPUBuffer(device, b);
            if (self.batch_transfer) |t| c.SDL_ReleaseGPUTransferBuffer(device, t);
            if (self.cluster_light_buffer) |b| c.SDL_ReleaseGPUBuffer(device, b);
            if (self.cluster_info_buffer) |b| c.SDL_ReleaseGPUBuffer(device, b);
            if (self.cluster_index_buffer) |b| c.SDL_ReleaseGPUBuffer(device, b);
            if (self.cluster_transfer) |t| c.SDL_ReleaseGPUTransferBuffer(device, t);
            if (self.shadow_atlas) |t| c.SDL_ReleaseGPUTexture(device, t);
            if (self.shadow_depth) |t| c.SDL_ReleaseGPUTexture(device, t);
            if (self.shadow_pipeline) |p| c.SDL_ReleaseGPUGraphicsPipeline(device, p);
            if (self.shadow_sampler) |s| c.SDL_ReleaseGPUSampler(device, s);
            if (self.pipeline) |p| c.SDL_ReleaseGPUGraphicsPipeline(device, p);
            if (self.sdl_window) |w| c.SDL_DestroyWindow(w);
            c.SDL_DestroyGPUDevice(device);
            c.SDL_Quit();
        }
    }

    /// Enter the main loop: polls events, runs systems, renders. Returns on quit.
    pub fn run(self: *Engine) !void {
        const device = self.gpu_device orelse return error.NotInitialized;

        // Start debug server (non-fatal if it fails)
        self.dbg_server.start(self) catch |err| {
            std.debug.print("[debug-server] failed to start: {}\n", .{err});
        };
        defer self.dbg_server.stop();

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
                _ = c.cImGui_ImplSDL3_ProcessEvent(&event);
                if (event.type == c.SDL_EVENT_QUIT) running = false;
                if (event.type == c.SDL_EVENT_KEY_DOWN and event.key.scancode == c.SDL_SCANCODE_ESCAPE) running = false;
            }

            // Check for screenshot request (file-based trigger)
            self.checkScreenshotRequest();

            // ImGui new frame (before systems so user code can draw UI)
            c.cImGui_ImplSDLGPU3_NewFrame();
            c.cImGui_ImplSDL3_NewFrame();
            c.igNewFrame();

            // Run all systems via the flecs pipeline scheduler.
            // This ticks game systems (age, physics, fly_camera, user systems)
            // and internal flecs modules (REST API, stats).
            _ = ecs.progress(self.world, dt);

            // Process debug server requests (after systems, before rendering)
            self.dbg_server.drainRequests();

            // Check for Lua system hot-reload (mtime polling)
            self.lua_sys.checkHotReload();

            // Physics stats
            if (self.physics.system) |phys_sys| {
                self.stats.physics_active = phys_sys.getNumActiveBodies();
                self.stats.physics_total = phys_sys.getNumBodies();
            }

            // --- Frame rendering ---
            const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse continue;

            var swapchain_tex: ?*c.SDL_GPUTexture = null;
            var sw_w: u32 = 0;
            var sw_h: u32 = 0;
            if (!c.SDL_AcquireGPUSwapchainTexture(cmd, self.sdl_window, &swapchain_tex, &sw_w, &sw_h)) {
                c.igEndFrame();
                _ = c.SDL_SubmitGPUCommandBuffer(cmd);
                continue;
            }
            if (swapchain_tex == null) {
                c.igEndFrame();
                _ = c.SDL_SubmitGPUCommandBuffer(cmd);
                continue;
            }

            // Ensure post-process textures match swapchain size
            postprocess.ensureTextures(self, sw_w, sw_h) catch {
                _ = c.SDL_SubmitGPUCommandBuffer(cmd);
                continue;
            };

            const pf = c.SDL_GetPerformanceFrequency();

            // Phase 1: Prepare (draw list + entity data + batch computation + GPU uploads)
            const tp0 = c.SDL_GetPerformanceCounter();
            const frame = renderer.prepareFrame(self, sw_w, sw_h);
            // Single-pass: columnar ECS iteration + sort + batch computation + upload
            const draw_count_actual = renderer.prepareDrawData(self, cmd);
            const frame_with_draws = renderer.FrameContext{
                .dir_light = frame.dir_light,
                .draw_count = draw_count_actual,
                .light_count = frame.light_count,
            };
            self.stats.entities_rendered = draw_count_actual;
            self.stats.draw_calls = self.batch_count;
            self.stats.visible_after_cull = self.culling_stats.visible_count;
            self.stats.frustum_culled = self.culling_stats.frustum_culled;
            self.stats.occlusion_culled = self.culling_stats.occlusion_culled;
            const tp1 = c.SDL_GetPerformanceCounter();
            self.stats.time_prepare_us = (tp1 - tp0) * 1_000_000 / pf;

            const hdr_tex = self.postprocess.hdr_texture.?;

            // Phase 1.4: Read back previous frame's culling stats (async, no stall)
            renderer.readbackCullingStats(self);

            // Phase 1.5: Build HiZ pyramid from previous frame's linear depth.
            // The HDR texture still holds last frame's render at this point
            // (alpha = linear camera distance). This builds the hierarchical
            // depth buffer used by the compute shader for occlusion culling.
            postprocess.buildHiZPyramid(self, cmd, sw_w, sw_h);

            // Per-camera rendering (persistent query — no per-frame allocation)
            var cam_qit = ecs.query_iter(self.world, self.camera_query.?);

            while (ecs.query_next(&cam_qit)) {
                for (cam_qit.entities()) |cam_entity| {
                    const cam = ecs.get(self.world, cam_entity, core_components.Camera) orelse continue;

                // Phase 2: Shadow map rendering (uploads its own instance data per cascade)
                const shadow_uniforms = renderer.executeShadowPass(self, cmd, cam_entity, sw_w, sw_h, frame_with_draws);

                // Phase 2.5: Compute dispatch for scene instance data (after shadow pass overwrote buffer)
                const ti0 = c.SDL_GetPerformanceCounter();
                renderer.dispatchInstanceData(self, cmd, cam_entity, sw_w, sw_h, frame_with_draws);
                const ti1 = c.SDL_GetPerformanceCounter();
                self.stats.time_instances_us = (ti1 - ti0) * 1_000_000 / pf;

                // Phase 2.7: Cluster assignment + upload (per-camera)
                renderer.updateClusters(self, cmd, cam_entity);

                // Phase 3: Scene render pass
                const ts0 = c.SDL_GetPerformanceCounter();
                renderer.executeScenePass(self, cmd, cam_entity, hdr_tex, sw_w, sw_h, frame_with_draws, cam.exposure, shadow_uniforms);
                const ts1 = c.SDL_GetPerformanceCounter();
                self.stats.time_scene_us = (ts1 - ts0) * 1_000_000 / pf;

                // Phase 3.5: Volumetric fog (after scene, before post-process)
                const vp = renderer.computeVPPublic(self, cam_entity, sw_w, sw_h);
                const cam_pos_arr = if (ecs.get(self.world, cam_entity, core_components.Position)) |p|
                    [4]f32{ p.x, p.y, p.z, 0 }
                else
                    [4]f32{ 0, 0, 0, 0 };

                if (self.vol_fog_enabled) {
                    const fog_shadow = postprocess.FogShadowData{
                        .light_vp = shadow_uniforms.light_vp,
                        .cascade_splits = shadow_uniforms.cascade_splits,
                        .shadow_params = shadow_uniforms.shadow_params,
                    };
                    postprocess.dispatchVolumetricFog(self, cmd, vp.m, vp.invert().m, cam_pos_arr, cam.near, cam.far, sw_w, sw_h, fog_shadow);
                }

                // Phase 4: Post-process (DoF + bloom + composite)
                const tpp0 = c.SDL_GetPerformanceCounter();

                const settings = postprocess.CameraPostSettings{
                    .exposure = cam.exposure,
                    .bloom_intensity = cam.bloom_intensity,
                    .dof_focus_dist = cam.dof_focus_dist,
                    .dof_focus_range = cam.dof_focus_range,
                    .dof_blur_radius = cam.dof_blur_radius,
                    .ssr_intensity = cam.ssr_intensity,
                    .ssr_max_distance = cam.ssr_max_distance,
                    .ssr_stride = cam.ssr_stride,
                    .ssr_thickness = cam.ssr_thickness,
                    .vp = vp.m,
                    .inv_vp = vp.invert().m,
                    .camera_pos = cam_pos_arr,
                    .camera_near = cam.near,
                    .prev_vp = self.prev_vp,
                    .frame_index = @floatFromInt(self.current_frame % 256),
                    .vignette_intensity = cam.vignette,
                    .vignette_smoothness = cam.vignette_smoothness,
                    .chromatic_aberration = cam.chromatic_aberration,
                    .grain_intensity = cam.grain,
                    .color_temp = cam.color_temp,
                    .flare_intensity = cam.flare_intensity,
                    .flare_ghost_dispersal = cam.flare_ghost_dispersal,
                    .flare_halo_width = cam.flare_halo_width,
                    .flare_chroma_distortion = cam.flare_chroma_distortion,
                    .flare_dirt_intensity = cam.flare_dirt_intensity,
                };
                // When capturing a screenshot, render to an intermediate texture
                // instead of the swapchain (Metal swapchain is framebufferOnly).
                const render_target = if (self.screenshot_requested)
                    self.ensureScreenshotTexture(device, sw_w, sw_h) orelse swapchain_tex.?
                else
                    swapchain_tex.?;

                postprocess.executePostProcess(self, cmd, render_target, sw_w, sw_h, settings);
                const tpp1 = c.SDL_GetPerformanceCounter();
                self.stats.time_postprocess_us = (tpp1 - tpp0) * 1_000_000 / pf;
                }
            }

            // Phase 5: ImGui overlay
            const tui0 = c.SDL_GetPerformanceCounter();
            c.igRender();
            const draw_data = c.igGetDrawData();
            if (draw_data != null) {
                c.cImGui_ImplSDLGPU3_PrepareDrawData(draw_data, cmd);

                const imgui_target = if (self.screenshot_requested and self.screenshot_texture != null)
                    self.screenshot_texture.?
                else
                    swapchain_tex.?;

                const imgui_color_target = c.SDL_GPUColorTargetInfo{
                    .texture = imgui_target,
                    .mip_level = 0,
                    .layer_or_depth_plane = 0,
                    .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                    .load_op = c.SDL_GPU_LOADOP_LOAD,
                    .store_op = c.SDL_GPU_STOREOP_STORE,
                    .resolve_texture = null,
                    .resolve_mip_level = 0,
                    .resolve_layer = 0,
                    .cycle = false,
                    .cycle_resolve_texture = false,
                    .padding1 = 0,
                    .padding2 = 0,
                };
                const imgui_pass = c.SDL_BeginGPURenderPass(cmd, &imgui_color_target, 1, null);
                if (imgui_pass) |pass| {
                    c.cImGui_ImplSDLGPU3_RenderDrawData(draw_data, cmd, pass);
                    c.SDL_EndGPURenderPass(pass);
                }
            }
            const tui1 = c.SDL_GetPerformanceCounter();
            self.stats.time_imgui_us = (tui1 - tui0) * 1_000_000 / pf;

            self.stats.accumulate();

            // Screenshot: blit to swapchain + download from intermediate texture
            if (self.screenshot_requested and self.screenshot_texture != null) {
                // Blit intermediate → swapchain so the frame is still displayed
                const blit_info = c.SDL_GPUBlitInfo{
                    .source = .{
                        .texture = self.screenshot_texture.?,
                        .mip_level = 0,
                        .layer_or_depth_plane = 0,
                        .x = 0,
                        .y = 0,
                        .w = sw_w,
                        .h = sw_h,
                    },
                    .destination = .{
                        .texture = swapchain_tex.?,
                        .mip_level = 0,
                        .layer_or_depth_plane = 0,
                        .x = 0,
                        .y = 0,
                        .w = sw_w,
                        .h = sw_h,
                    },
                    .load_op = c.SDL_GPU_LOADOP_DONT_CARE,
                    .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                    .flip_mode = c.SDL_FLIP_NONE,
                    .filter = c.SDL_GPU_FILTER_NEAREST,
                    .cycle = false,
                    .padding1 = 0,
                    .padding2 = 0,
                    .padding3 = 0,
                };
                c.SDL_BlitGPUTexture(cmd, &blit_info);

                self.downloadScreenshot(device, cmd, sw_w, sw_h);
                self.screenshot_requested = false;
                // If this screenshot was triggered by the debug server, complete the HTTP response
                self.dbg_server.completeScreenshot();
            } else {
                _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            }

            // Debug stats to console (once per second)
            if (self.debug_stats and self.stats.acc_frames == 0 and self.current_frame > 0) {
                self.printDebugStats();
            }
        }
    }

    fn printDebugStats(self: *Engine) void {
        const s = self.stats;
        const io = c.igGetIO();
        const fps: f32 = if (io) |i| i.*.Framerate else 0;

        std.debug.print(
            \\[stats] {d:.0}fps | {d} draws ({d} entities) | physics {d}/{d}
            \\  prepare {d:.2}ms | instances {d:.2}ms | scene {d:.2}ms | postprocess {d:.2}ms | imgui {d:.2}ms
            \\
        , .{
            fps,
            s.draw_calls,
            s.entities_rendered,
            s.physics_active,
            s.physics_total,
            s.avg_prepare / 1000.0,
            s.avg_instances / 1000.0,
            s.avg_scene / 1000.0,
            s.avg_postprocess / 1000.0,
            s.avg_imgui / 1000.0,
        });

        // Per-system timing available via Flecs Explorer
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

        self.sdl_window = c.SDL_CreateWindow(config.title, @intCast(config.width), @intCast(config.height), c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY);
        if (self.sdl_window == null) {
            std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
            return error.SDLWindowFailed;
        }

        if (!c.SDL_ClaimWindowForGPUDevice(self.gpu_device.?, self.sdl_window)) {
            std.debug.print("SDL_ClaimWindowForGPUDevice failed: {s}\n", .{c.SDL_GetError()});
            return error.ClaimWindowFailed;
        }

        // Enable vsync to avoid burning CPU/GPU at uncapped frame rates.
        _ = c.SDL_SetGPUSwapchainParameters(self.gpu_device.?, self.sdl_window, c.SDL_GPU_SWAPCHAINCOMPOSITION_SDR, c.SDL_GPU_PRESENTMODE_VSYNC);

        // Default sampler (linear filtering, repeat wrap)
        self.assets.default_sampler = c.SDL_CreateGPUSampler(self.gpu_device.?, &c.SDL_GPUSamplerCreateInfo{
            .min_filter = c.SDL_GPU_FILTER_LINEAR,
            .mag_filter = c.SDL_GPU_FILTER_LINEAR,
            .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_LINEAR,
            .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_REPEAT,
            .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_REPEAT,
            .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_REPEAT,
            .mip_lod_bias = 0,
            .max_anisotropy = 1,
            .compare_op = 0,
            .min_lod = 0,
            .max_lod = 1000,
            .enable_anisotropy = false,
            .enable_compare = false,
            .padding1 = 0,
            .padding2 = 0,
            .props = 0,
        }) orelse {
            std.debug.print("Failed to create default sampler: {s}\n", .{c.SDL_GetError()});
            return error.SamplerFailed;
        };

        // 1x1 white dummy texture (bound when material has no texture)
        const white_pixel = [4]u8{ 255, 255, 255, 255 };
        self.assets.dummy_texture = try self.createDummyTexture(&white_pixel);

        // Pipeline + render targets
        try renderer.initPipeline(self, config);

        // Merged geometry buffers: all mesh vertex/index data lives in these.
        // Created once at init, appended to by createMesh().
        self.merged_vertex_buffer = c.SDL_CreateGPUBuffer(self.gpu_device.?, &c.SDL_GPUBufferCreateInfo{
            .usage = c.SDL_GPU_BUFFERUSAGE_VERTEX,
            .size = max_merged_vertices * @sizeOf(geometry.Vertex),
            .props = 0,
        }) orelse return error.BufferFailed;
        self.merged_index_buffer = c.SDL_CreateGPUBuffer(self.gpu_device.?, &c.SDL_GPUBufferCreateInfo{
            .usage = c.SDL_GPU_BUFFERUSAGE_INDEX,
            .size = max_merged_indices * @sizeOf(u32),
            .props = 0,
        }) orelse return error.BufferFailed;

        // Indirect draw: batch info (readonly by compute) and indirect draw commands
        // (written by compute via atomics, consumed by indirect draw calls).
        self.batch_info_buffer = c.SDL_CreateGPUBuffer(self.gpu_device.?, &c.SDL_GPUBufferCreateInfo{
            .usage = c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ,
            .size = renderer.max_batches * @sizeOf(renderer.BatchInfo),
            .props = 0,
        }) orelse return error.BufferFailed;
        self.indirect_draw_buffer = c.SDL_CreateGPUBuffer(self.gpu_device.?, &c.SDL_GPUBufferCreateInfo{
            .usage = c.SDL_GPU_BUFFERUSAGE_INDIRECT | c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE,
            .size = renderer.max_batches * @sizeOf(renderer.IndirectDrawCommand),
            .props = 0,
        }) orelse return error.BufferFailed;
        // Single transfer buffer for both batch info + indirect commands (uploaded together)
        const batch_transfer_size = renderer.max_batches * (@sizeOf(renderer.BatchInfo) + @sizeOf(renderer.IndirectDrawCommand));
        self.batch_transfer = c.SDL_CreateGPUTransferBuffer(self.gpu_device.?, &c.SDL_GPUTransferBufferCreateInfo{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = batch_transfer_size,
            .props = 0,
        }) orelse return error.BufferFailed;

        // Instance buffer for batched rendering.
        // Readable by the vertex shader (GRAPHICS_STORAGE_READ) and writable by
        // the instance setup compute shader (COMPUTE_STORAGE_WRITE).
        const instance_buf_size: u32 = renderer.max_renderables * @sizeOf(renderer.InstanceData);
        self.instance_buffer = c.SDL_CreateGPUBuffer(self.gpu_device.?, &c.SDL_GPUBufferCreateInfo{
            .usage = c.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ | c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE,
            .size = instance_buf_size,
            .props = 0,
        }) orelse return error.BufferFailed;
        self.instance_transfer = c.SDL_CreateGPUTransferBuffer(self.gpu_device.?, &c.SDL_GPUTransferBufferCreateInfo{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = instance_buf_size,
            .props = 0,
        }) orelse return error.BufferFailed;

        // Entity data buffer for GPU-driven instance setup.
        // Raw per-entity transforms uploaded from CPU, read by the compute shader.
        const entity_buf_size: u32 = renderer.max_renderables * @sizeOf(renderer.EntityData);
        self.entity_data_buffer = c.SDL_CreateGPUBuffer(self.gpu_device.?, &c.SDL_GPUBufferCreateInfo{
            .usage = c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ,
            .size = entity_buf_size,
            .props = 0,
        }) orelse return error.BufferFailed;
        // Transfer buffer holds entity data + batch info + indirect commands + culling stats (single map/unmap)
        const batch_data_size = renderer.max_batches * (@sizeOf(renderer.BatchInfo) + @sizeOf(renderer.IndirectDrawCommand));
        self.entity_data_transfer = c.SDL_CreateGPUTransferBuffer(self.gpu_device.?, &c.SDL_GPUTransferBufferCreateInfo{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = entity_buf_size + batch_data_size + @sizeOf(renderer.CullingStats),
            .props = 0,
        }) orelse return error.BufferFailed;
        self.instance_capacity = renderer.max_renderables;

        // Clustered lighting buffers
        const light_buf_size: u32 = renderer.max_lights * @sizeOf(renderer.GPULight);
        const info_buf_size: u32 = renderer.num_clusters * @sizeOf(renderer.ClusterInfo);
        const index_buf_size: u32 = renderer.max_light_indices * @sizeOf(u32);
        const cluster_transfer_size: u32 = light_buf_size + info_buf_size + index_buf_size;

        self.cluster_light_buffer = c.SDL_CreateGPUBuffer(self.gpu_device.?, &c.SDL_GPUBufferCreateInfo{
            .usage = c.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ,
            .size = light_buf_size,
            .props = 0,
        }) orelse return error.BufferFailed;
        self.cluster_info_buffer = c.SDL_CreateGPUBuffer(self.gpu_device.?, &c.SDL_GPUBufferCreateInfo{
            .usage = c.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ,
            .size = info_buf_size,
            .props = 0,
        }) orelse return error.BufferFailed;
        self.cluster_index_buffer = c.SDL_CreateGPUBuffer(self.gpu_device.?, &c.SDL_GPUBufferCreateInfo{
            .usage = c.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ,
            .size = index_buf_size,
            .props = 0,
        }) orelse return error.BufferFailed;
        self.cluster_transfer = c.SDL_CreateGPUTransferBuffer(self.gpu_device.?, &c.SDL_GPUTransferBufferCreateInfo{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = cluster_transfer_size,
            .props = 0,
        }) orelse return error.BufferFailed;

        // Post-processing (bloom)
        try postprocess.initPostProcess(self);

        // Cascaded shadow maps
        // Shadow atlas: R32_FLOAT color target (stores depth values, sampleable)
        self.shadow_atlas = c.SDL_CreateGPUTexture(self.gpu_device.?, &c.SDL_GPUTextureCreateInfo{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = c.SDL_GPU_TEXTUREFORMAT_R32_FLOAT,
            .usage = c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = renderer.shadow_atlas_size,
            .height = renderer.shadow_atlas_size,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
            .props = 0,
        }) orelse return error.BufferFailed;
        // Shadow depth: D32_FLOAT for z-testing during shadow pass
        self.shadow_depth = c.SDL_CreateGPUTexture(self.gpu_device.?, &c.SDL_GPUTextureCreateInfo{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = c.SDL_GPU_TEXTUREFORMAT_D32_FLOAT,
            .usage = c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET,
            .width = renderer.shadow_atlas_size,
            .height = renderer.shadow_atlas_size,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
            .props = 0,
        }) orelse return error.BufferFailed;
        self.shadow_sampler = c.SDL_CreateGPUSampler(self.gpu_device.?, &c.SDL_GPUSamplerCreateInfo{
            .min_filter = c.SDL_GPU_FILTER_NEAREST,
            .mag_filter = c.SDL_GPU_FILTER_NEAREST,
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
        }) orelse return error.BufferFailed;
        try renderer.initShadowPipeline(self);
        try renderer.initComputePipeline(self);

        // Persistent ECS queries — created once, reused every frame.
        // Flecs automatically maintains these as entities are added/removed.
        self.renderable_query = renderer.createRenderableQuery(self.world);
        self.dir_light_query = queryInit(self.world, &.{ecs.id(core_components.DirectionalLight)}, &.{});
        self.point_light_query = queryInit(self.world, &.{ ecs.id(core_components.Position), ecs.id(core_components.PointLight) }, &.{});
        self.spot_light_query = queryInit(self.world, &.{ ecs.id(core_components.Position), ecs.id(core_components.SpotLight) }, &.{});
        self.camera_query = queryInit(self.world, &.{ ecs.id(core_components.Position), ecs.id(core_components.Camera) }, &.{});

        // Dear ImGui
        _ = c.igCreateContext(null);
        styleImGui();

        // Load custom font at display-native resolution (HiDPI-aware).
        // Rasterize at physical pixels, then tell ImGui the DPI scale so it
        // uses the high-res glyphs at logical size.
        const dpi_scale = c.SDL_GetWindowDisplayScale(self.sdl_window);
        const font_size: f32 = 16.0 * dpi_scale;
        const io = c.igGetIO();
        if (io) |imgui_io| {
            const font = c.ImFontAtlas_AddFontFromFileTTF(imgui_io.*.Fonts, "assets/fonts/IBMPlexSans-Regular.ttf", font_size, null, null);
            if (font == null) {
                std.debug.print("ImGui: custom font not found, using default\n", .{});
            }
        }
        const style = c.igGetStyle();
        style.*.FontScaleDpi = 1.0 / dpi_scale;

        if (!c.cImGui_ImplSDL3_InitForSDLGPU(self.sdl_window)) {
            std.debug.print("ImGui SDL3 init failed\n", .{});
            return error.ImGuiInitFailed;
        }
        var gpu_init_info = c.cImGui_ImplSDLGPU3_InitInfo{
            .Device = self.gpu_device.?,
            .ColorTargetFormat = self.swapchain_format,
            .MSAASamples = c.SDL_GPU_SAMPLECOUNT_1,
        };
        if (!c.cImGui_ImplSDLGPU3_Init(&gpu_init_info)) {
            std.debug.print("ImGui SDL_GPU init failed\n", .{});
            return error.ImGuiInitFailed;
        }

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

        // Physics
        try physics.initPhysics(self);

        // Built-in Zig systems.
        // Systems with known component dependencies use proper flecs query terms
        // so the scheduler can manage sync points and parallelism automatically.
        // Systems with complex/external access patterns (physics, ImGui) use
        // immediate + defer_suspend as a justified escape hatch.
        {
            // age: increments Age.seconds. Pure ECS, fully parallelizable.
            _ = ecs.ADD_SYSTEM(self.world, "age", ecs.OnUpdate, ageSystemFlecs);

            // fly_camera: reads FlyCamera, writes Position+Rotation. Pure ECS.
            // Needs Engine ctx for keyboard input, so use SYSTEM_DESC + set ctx.
            {
                var fc_desc = ecs.SYSTEM_DESC(flyCameraSystemFlecs);
                fc_desc.phase = ecs.OnUpdate;
                fc_desc.ctx = self;
                _ = ecs.SYSTEM(self.world, "fly_camera", &fc_desc);
            }

            // physics: complex Jolt interop — needs immediate + defer_suspend.
            // Uses flecs interval for fixed timestep (1/60s). Flecs handles the
            // accumulator and calls the system multiple times per frame if needed.
            {
                var phys_desc = std.mem.zeroes(ecs.system_desc_t);
                phys_desc.callback = zigSystemCallback(&physics.physicsSystem);
                phys_desc.ctx = self;
                phys_desc.phase = ecs.OnUpdate;
                phys_desc.immediate = true;
                phys_desc.interval = physics.physics_timestep;
                _ = ecs.SYSTEM(self.world, "physics", &phys_desc);
            }

            // stats_overlay: ImGui overlay, no ECS deps — needs immediate (ImGui context).
            self.addSystem("stats_overlay", &Engine.statsOverlaySystem, ecs.OnStore);
        }
    }

    // ---- Mesh API ----

    /// Upload vertex (and optional index) data to the GPU. Returns a mesh handle.
    /// Pass a name for built-in meshes (used for name-based lookup), or null.
    pub fn createMesh(self: *Engine, name: ?[*:0]const u8, vertices: []const Vertex, indices: ?[]const u32) !u32 {
        const device = self.gpu_device orelse return error.NotInitialized;
        const vcount: u32 = @intCast(vertices.len);
        const icount: u32 = if (indices) |idx| @as(u32, @intCast(idx.len)) else 0;

        // Check merged buffer capacity
        if (self.merged_vertex_offset + vcount > max_merged_vertices) return error.TooManyVertices;
        if (indices != null and self.merged_index_offset + icount > max_merged_indices) return error.TooManyIndices;

        const base_vertex = self.merged_vertex_offset;
        const first_index = self.merged_index_offset;

        // Upload vertices to merged vertex buffer at current offset
        uploadToBufferRegion(device, self.merged_vertex_buffer.?, std.mem.sliceAsBytes(vertices), base_vertex * @sizeOf(Vertex));
        self.merged_vertex_offset += vcount;

        // Upload indices to merged index buffer at current offset
        if (indices) |idx| {
            uploadToBufferRegion(device, self.merged_index_buffer.?, std.mem.sliceAsBytes(idx), first_index * @sizeOf(u32));
            self.merged_index_offset += icount;
        }

        // Try to reuse a freed slot
        var id: u32 = self.assets.mesh_count;
        for (0..self.assets.mesh_count) |i| {
            if (self.assets.mesh_registry[i] == null) {
                id = @intCast(i);
                break;
            }
        }
        if (id == self.assets.mesh_count) {
            if (self.assets.mesh_count >= max_meshes) return error.TooManyMeshes;
            self.assets.mesh_count += 1;
        }

        self.assets.mesh_registry[id] = .{
            .vertex_count = vcount,
            .index_count = icount,
            .base_vertex = base_vertex,
            .first_index = first_index,
            .indexed = indices != null,
        };
        self.assets.mesh_names[id] = name;
        return id;
    }

    /// Destroy a mesh, freeing the registry slot.
    /// The vertex/index data remains in the merged buffers (no compaction).
    /// The slot can be reused by a future createMesh call.
    pub fn destroyMesh(self: *Engine, id: u32) void {
        if (id >= self.assets.mesh_count) return;
        self.assets.mesh_registry[id] = null;
        self.assets.mesh_names[id] = null;
    }

    /// Generate and upload a unit cube mesh. Returns a mesh handle.
    pub fn createCubeMesh(self: *Engine) !u32 {
        const allocator = std.heap.c_allocator;
        const mesh = try geometry.cube(allocator);
        defer allocator.free(mesh.vertices);
        defer allocator.free(mesh.indices);
        return self.createMesh(null, mesh.vertices, mesh.indices);
    }

    /// Generate and upload a UV sphere mesh. Returns a mesh handle.
    pub fn createSphereMesh(self: *Engine, segments: u32, rings: u32) !u32 {
        const allocator = std.heap.c_allocator;
        const mesh = try geometry.sphere(allocator, segments, rings);
        defer allocator.free(mesh.vertices);
        defer allocator.free(mesh.indices);
        return self.createMesh(null, mesh.vertices, mesh.indices);
    }

    /// Look up a named mesh by string. Returns the handle or null.
    pub fn findMesh(self: *Engine, name: [*:0]const u8) ?u32 {
        return self.assets.findMesh(name);
    }

    // ---- Material API ----

    /// Create an unnamed material. Returns a material handle.
    pub fn createMaterial(self: *Engine, data: MaterialData) !u32 {
        return self.createNamedMaterial(null, data);
    }

    /// Create a material with an optional name (used for name-based lookup).
    pub fn createNamedMaterial(self: *Engine, name: ?[*:0]const u8, data: MaterialData) !u32 {
        // First try to reuse a freed slot
        for (0..self.assets.material_count) |i| {
            if (self.assets.material_registry[i] == null) {
                self.assets.material_registry[i] = data;
                self.assets.material_names[i] = name;
                return @intCast(i);
            }
        }
        // Otherwise append
        if (self.assets.material_count >= max_materials) return error.TooManyMaterials;
        const id = self.assets.material_count;
        self.assets.material_registry[id] = data;
        self.assets.material_names[id] = name;
        self.assets.material_count += 1;
        return id;
    }

    /// Destroy a material, freeing its registry slot for reuse.
    pub fn destroyMaterial(self: *Engine, id: u32) void {
        if (id >= self.assets.material_count) return;
        self.assets.material_registry[id] = null;
        self.assets.material_names[id] = null;
    }

    /// Look up a named material by string. Returns the handle or null.
    pub fn findMaterial(self: *Engine, name: [*:0]const u8) ?u32 {
        return self.assets.findMaterial(name);
    }

    fn createDummyTexture(self: *Engine, pixel: *const [4]u8) !*c.SDL_GPUTexture {
        const id = try self.createTextureFromMemory(pixel, 1, 1);
        return self.assets.texture_registry[id].?.texture;
    }

    // ---- Texture API ----

    /// Create a texture from raw RGBA pixel data. Returns a texture handle.
    pub fn createTextureFromMemory(self: *Engine, pixels: [*]const u8, width: u32, height: u32) !u32 {
        if (self.assets.texture_count >= max_textures) return error.TooManyTextures;
        const device = self.gpu_device orelse return error.NotInitialized;
        const sampler = self.assets.default_sampler orelse return error.NotInitialized;

        const tex = c.SDL_CreateGPUTexture(device, &c.SDL_GPUTextureCreateInfo{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
            .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = width,
            .height = height,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
            .props = 0,
        }) orelse return error.TextureFailed;

        // Upload pixel data
        const data_size = width * height * 4;
        const transfer = c.SDL_CreateGPUTransferBuffer(device, &c.SDL_GPUTransferBufferCreateInfo{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = data_size,
            .props = 0,
        }) orelse {
            c.SDL_ReleaseGPUTexture(device, tex);
            return error.BufferFailed;
        };

        const ptr = c.SDL_MapGPUTransferBuffer(device, transfer, false) orelse {
            c.SDL_ReleaseGPUTransferBuffer(device, transfer);
            c.SDL_ReleaseGPUTexture(device, tex);
            return error.BufferFailed;
        };
        @memcpy(@as([*]u8, @ptrCast(ptr))[0..data_size], pixels[0..data_size]);
        c.SDL_UnmapGPUTransferBuffer(device, transfer);

        const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse {
            c.SDL_ReleaseGPUTransferBuffer(device, transfer);
            c.SDL_ReleaseGPUTexture(device, tex);
            return error.BufferFailed;
        };
        const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            c.SDL_ReleaseGPUTransferBuffer(device, transfer);
            c.SDL_ReleaseGPUTexture(device, tex);
            return error.BufferFailed;
        };
        c.SDL_UploadToGPUTexture(copy_pass, &c.SDL_GPUTextureTransferInfo{
            .transfer_buffer = transfer,
            .offset = 0,
            .pixels_per_row = width,
            .rows_per_layer = height,
        }, &c.SDL_GPUTextureRegion{
            .texture = tex,
            .mip_level = 0,
            .layer = 0,
            .x = 0,
            .y = 0,
            .z = 0,
            .w = width,
            .h = height,
            .d = 1,
        }, false);
        c.SDL_EndGPUCopyPass(copy_pass);
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
        c.SDL_ReleaseGPUTransferBuffer(device, transfer);

        const id = self.assets.texture_count;
        self.assets.texture_registry[id] = .{
            .texture = tex,
            .sampler = sampler,
            .width = width,
            .height = height,
        };
        self.assets.texture_count += 1;
        return id;
    }

    /// Load an image file (PNG, JPEG, etc.) and create a GPU texture. Returns a texture handle.
    pub fn createTextureFromFile(self: *Engine, path: [*:0]const u8) !u32 {
        var w: c_int = 0;
        var h: c_int = 0;
        var channels: c_int = 0;
        const pixels = stbi.stbi_load(path, &w, &h, &channels, 4) orelse return error.ImageLoadFailed;
        defer stbi.stbi_image_free(pixels);
        return self.createTextureFromMemory(@ptrCast(pixels), @intCast(w), @intCast(h));
    }

    // ---- Screenshot ----

    /// Scan `tmp/` for any `*.request` file. If found, derive the output path by
    /// replacing `.request` with `.png`, delete the trigger, and set the screenshot flag.
    /// Example: `tmp/shot1.request` → `tmp/shot1.png`.
    fn checkScreenshotRequest(self: *Engine) void {
        const cwd = std.fs.cwd();
        var dir = cwd.openDir("tmp", .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        const entry = (iter.next() catch return) orelse return;
        // Keep iterating until we find a .request file
        var name = entry.name;
        var found = std.mem.endsWith(u8, name, ".request");
        while (!found) {
            const next = (iter.next() catch return) orelse return;
            name = next.name;
            found = std.mem.endsWith(u8, name, ".request");
        }
        if (!found) return;

        // Build output path: tmp/<basename>.png
        const stem_len = name.len - ".request".len;
        const prefix = "tmp/";
        const suffix = ".png";
        const total = prefix.len + stem_len + suffix.len;
        if (total > self.screenshot_path_buf.len) return;

        @memcpy(self.screenshot_path_buf[0..prefix.len], prefix);
        @memcpy(self.screenshot_path_buf[prefix.len..][0..stem_len], name[0..stem_len]);
        @memcpy(self.screenshot_path_buf[prefix.len + stem_len ..][0..suffix.len], suffix);
        self.screenshot_path_len = @intCast(total);

        // Delete the trigger file
        dir.deleteFile(name) catch {};
        self.screenshot_requested = true;
    }

    /// Ensure the screenshot intermediate texture exists at the right size.
    fn ensureScreenshotTexture(self: *Engine, device: *c.SDL_GPUDevice, w: u32, h: u32) ?*c.SDL_GPUTexture {
        if (self.screenshot_texture != null and self.screenshot_tex_w == w and self.screenshot_tex_h == h) {
            return self.screenshot_texture;
        }
        if (self.screenshot_texture) |t| c.SDL_ReleaseGPUTexture(device, t);

        self.screenshot_texture = c.SDL_CreateGPUTexture(device, &c.SDL_GPUTextureCreateInfo{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = self.swapchain_format,
            .usage = c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = w,
            .height = h,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
            .props = 0,
        });
        self.screenshot_tex_w = w;
        self.screenshot_tex_h = h;
        return self.screenshot_texture;
    }

    /// Download the screenshot texture to a PNG file.
    fn downloadScreenshot(self: *Engine, device: *c.SDL_GPUDevice, cmd: *c.SDL_GPUCommandBuffer, w: u32, h: u32) void {
        const screenshot_tex = self.screenshot_texture orelse {
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            return;
        };
        const data_size = w * h * 4;

        const transfer = c.SDL_CreateGPUTransferBuffer(device, &c.SDL_GPUTransferBufferCreateInfo{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD,
            .size = data_size,
            .props = 0,
        }) orelse {
            std.debug.print("[screenshot] failed to create transfer buffer\n", .{});
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            return;
        };

        const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse {
            std.debug.print("[screenshot] failed to begin copy pass\n", .{});
            c.SDL_ReleaseGPUTransferBuffer(device, transfer);
            _ = c.SDL_SubmitGPUCommandBuffer(cmd);
            return;
        };

        c.SDL_DownloadFromGPUTexture(copy_pass, &c.SDL_GPUTextureRegion{
            .texture = screenshot_tex,
            .mip_level = 0,
            .layer = 0,
            .x = 0,
            .y = 0,
            .z = 0,
            .w = w,
            .h = h,
            .d = 1,
        }, &c.SDL_GPUTextureTransferInfo{
            .transfer_buffer = transfer,
            .offset = 0,
            .pixels_per_row = w,
            .rows_per_layer = h,
        });
        c.SDL_EndGPUCopyPass(copy_pass);

        const fence = c.SDL_SubmitGPUCommandBufferAndAcquireFence(cmd);
        if (fence == null) {
            std.debug.print("[screenshot] failed to acquire fence\n", .{});
            c.SDL_ReleaseGPUTransferBuffer(device, transfer);
            return;
        }
        _ = c.SDL_WaitForGPUFences(device, true, @ptrCast(&fence), 1);
        c.SDL_ReleaseGPUFence(device, fence);

        const ptr = c.SDL_MapGPUTransferBuffer(device, transfer, false) orelse {
            std.debug.print("[screenshot] failed to map transfer buffer\n", .{});
            c.SDL_ReleaseGPUTransferBuffer(device, transfer);
            return;
        };
        const pixels: [*]u8 = @ptrCast(ptr);

        // Swizzle BGRA → RGBA in-place
        var i: u32 = 0;
        while (i < data_size) : (i += 4) {
            const tmp = pixels[i];
            pixels[i] = pixels[i + 2];
            pixels[i + 2] = tmp;
        }

        // Null-terminate the path for C
        const path_len = self.screenshot_path_len;
        self.screenshot_path_buf[path_len] = 0;
        const path: [*:0]const u8 = @ptrCast(self.screenshot_path_buf[0..path_len :0]);

        const result = stbiw.stbi_write_png(
            path,
            @intCast(w),
            @intCast(h),
            4,
            pixels,
            @intCast(w * 4),
        );

        c.SDL_UnmapGPUTransferBuffer(device, transfer);
        c.SDL_ReleaseGPUTransferBuffer(device, transfer);

        if (result != 0) {
            std.debug.print("[screenshot] saved {s} ({}x{})\n", .{ path, w, h });
        } else {
            std.debug.print("[screenshot] failed to write {s}\n", .{path});
        }
    }

    // ---- Input API ----

    /// Get relative mouse movement since the last call. Requires mouse grab to be enabled.
    pub fn getMouseDelta(self: *Engine) struct { dx: f32, dy: f32 } {
        _ = self;
        var dx: f32 = 0;
        var dy: f32 = 0;
        _ = c.SDL_GetRelativeMouseState(&dx, &dy);
        return .{ .dx = dx, .dy = dy };
    }

    /// Enable or disable relative mouse mode (hides cursor, provides delta movement).
    pub fn setMouseGrab(self: *Engine, grab: bool) void {
        if (self.sdl_window) |win| {
            _ = c.SDL_SetWindowRelativeMouseMode(win, grab);
        }
    }

    // ---- Math utilities ----

    pub const CameraAxes = struct {
        forward: [3]f32,
        right: [3]f32,
    };

    /// Compute forward and right direction vectors from euler angles (degrees).
    /// Uses the same rotation convention as the renderer (Rz * Ry * Rx, camera looks down -Z).
    pub fn getCameraAxes(rx: f32, ry: f32, rz: f32) CameraAxes {
        const rot = Mat4.mul(Mat4.mul(Mat4.rotateZ(rz), Mat4.rotateY(ry)), Mat4.rotateX(rx));
        return .{
            .forward = .{ -rot.m[2][0], -rot.m[2][1], -rot.m[2][2] },
            .right = .{ rot.m[0][0], rot.m[0][1], rot.m[0][2] },
        };
    }

    // ---- Input helpers ----

    /// Check if a keyboard key is currently pressed.
    pub fn isKeyDown(_: *Engine, scancode: c_uint) bool {
        const state = c.SDL_GetKeyboardState(null);
        return state[scancode];
    }

    // ---- System management ----

    /// Register a Zig system as its own flecs pipeline system.
    /// Each gets a comptime-specialized callback. `immediate=true` so
    /// mutations apply instantly (no deferred queue).
    pub fn addSystem(self: *Engine, name: [*:0]const u8, comptime func: ZigSystemFn, phase: ecs.entity_t) void {
        var desc = std.mem.zeroes(ecs.system_desc_t);
        desc.callback = zigSystemCallback(func);
        desc.ctx = self;
        desc.phase = phase;
        desc.immediate = true;
        _ = ecs.SYSTEM(self.world, name, &desc);
    }

    /// Scan a directory for .lua files and auto-register each as a Lua system.
    /// Each .lua file must declare a `terms` table and a `system()` function.
    /// Component names are resolved automatically from the engine's component registry.
    pub fn loadLuaSystems(self: *Engine, dir_path: []const u8) void {
        self.lua_sys.scanDirectory(self, dir_path);
    }

    /// Register a Lua system with explicit terms (manual API).
    pub fn addLuaSystem(self: *Engine, desc: lua_systems.LuaSystemDesc) void {
        self.lua_sys.register(self, desc);
    }

    /// Tick all systems via the flecs pipeline.
    pub fn tickSystems(self: *Engine, dt: f32) void {
        _ = ecs.progress(self.world, dt);
    }

    // ---- Built-in systems ----

    /// Built-in stats overlay — top-right corner, always visible.
    pub fn statsOverlaySystem(self: *Engine, _: f32) void {
        const s = self.stats;
        const io = c.igGetIO();
        const display_w: f32 = if (io) |i| i.*.DisplaySize.x else 800;

        c.igSetNextWindowPosEx(.{ .x = display_w - 16, .y = 16 }, c.ImGuiCond_Always, .{ .x = 1, .y = 0 });
        c.igSetNextWindowSizeConstraints(.{ .x = 280, .y = 0 }, .{ .x = 280, .y = 10000 }, null, null);
        _ = c.igBegin("##stats", null, c.ImGuiWindowFlags_NoTitleBar | c.ImGuiWindowFlags_NoResize | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_AlwaysAutoResize | c.ImGuiWindowFlags_NoFocusOnAppearing | c.ImGuiWindowFlags_NoNav);

        var buf: [128]u8 = undefined;
        const line1 = std.fmt.bufPrintZ(&buf, "{d:.0} fps | {d} draws ({d} entities)", .{ if (io) |i| i.*.Framerate else 0, s.draw_calls, s.entities_rendered }) catch "???";
        c.igTextUnformatted(line1);

        var buf2: [128]u8 = undefined;
        const line2 = std.fmt.bufPrintZ(&buf2, "physics {d}/{d} active | rendered {d}", .{
            s.physics_active,
            s.physics_total,
            s.entities_rendered,
        }) catch "???";
        c.igTextUnformatted(line2);

        // GPU culling breakdown (from previous frame's compute shader readback)
        {
            const total = s.visible_after_cull + s.frustum_culled + s.occlusion_culled;
            if (total > 0 and c.igCollapsingHeader("Culling", 0)) {
                var cb1: [64]u8 = undefined;
                c.igTextUnformatted(std.fmt.bufPrintZ(&cb1, "total {d}", .{total}) catch "???");
                var cb2: [64]u8 = undefined;
                c.igTextUnformatted(std.fmt.bufPrintZ(&cb2, "visible {d}", .{s.visible_after_cull}) catch "???");
                var cb3: [64]u8 = undefined;
                c.igTextUnformatted(std.fmt.bufPrintZ(&cb3, "frustum culled {d}", .{s.frustum_culled}) catch "???");
                var cb4: [64]u8 = undefined;
                c.igTextUnformatted(std.fmt.bufPrintZ(&cb4, "occlusion culled {d}", .{s.occlusion_culled}) catch "???");
            }
        }

        // Render sub-phases
        if (c.igCollapsingHeader("Render", 0)) {
            const render_phases = [_]struct { name: []const u8, avg: f64 }{
                .{ .name = "prepare", .avg = s.avg_prepare },
                .{ .name = "instances", .avg = s.avg_instances },
                .{ .name = "scene", .avg = s.avg_scene },
                .{ .name = "postprocess", .avg = s.avg_postprocess },
                .{ .name = "imgui", .avg = s.avg_imgui },
            };

            for (render_phases) |phase| {
                var phase_buf: [128]u8 = undefined;
                const phase_line = std.fmt.bufPrintZ(&phase_buf, "{d:.2}ms {s}", .{
                    phase.avg / 1000.0,
                    phase.name,
                }) catch "???";
                c.igTextUnformatted(phase_line);
            }
        }

        c.igEnd();
    }

    // ageSystem and flyCameraSystem are now proper flecs systems with query
    // terms (see ageSystemFlecs / flyCameraSystemFlecs at file scope).

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

/// Upload data to a specific byte offset within an existing GPU buffer.
/// Used by createMesh to append vertex/index data to the merged geometry buffers.
fn uploadToBufferRegion(device: *c.SDL_GPUDevice, buffer: *c.SDL_GPUBuffer, data: []const u8, dest_offset: u32) void {
    const data_size: u32 = @intCast(data.len);
    if (data_size == 0) return;

    const transfer = c.SDL_CreateGPUTransferBuffer(device, &c.SDL_GPUTransferBufferCreateInfo{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = data_size,
        .props = 0,
    }) orelse return;

    const ptr = c.SDL_MapGPUTransferBuffer(device, transfer, false) orelse {
        c.SDL_ReleaseGPUTransferBuffer(device, transfer);
        return;
    };
    @memcpy(@as([*]u8, @ptrCast(ptr))[0..data_size], data);
    c.SDL_UnmapGPUTransferBuffer(device, transfer);

    const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse {
        c.SDL_ReleaseGPUTransferBuffer(device, transfer);
        return;
    };
    const copy_pass = c.SDL_BeginGPUCopyPass(cmd) orelse {
        _ = c.SDL_SubmitGPUCommandBuffer(cmd);
        c.SDL_ReleaseGPUTransferBuffer(device, transfer);
        return;
    };
    c.SDL_UploadToGPUBuffer(copy_pass, &c.SDL_GPUTransferBufferLocation{
        .transfer_buffer = transfer,
        .offset = 0,
    }, &c.SDL_GPUBufferRegion{
        .buffer = buffer,
        .offset = dest_offset,
        .size = data_size,
    }, false);
    c.SDL_EndGPUCopyPass(copy_pass);
    _ = c.SDL_SubmitGPUCommandBuffer(cmd);
    c.SDL_ReleaseGPUTransferBuffer(device, transfer);
}

// ============================================================
// ImGui theme
// ============================================================

fn styleImGui() void {
    const style = c.igGetStyle();
    c.igStyleColorsDark(style);

    // Geometry — rounded, spacious
    style.*.WindowRounding = 8;
    style.*.ChildRounding = 6;
    style.*.FrameRounding = 4;
    style.*.PopupRounding = 6;
    style.*.GrabRounding = 3;
    style.*.TabRounding = 4;
    style.*.ScrollbarRounding = 6;
    style.*.WindowPadding = .{ .x = 12, .y = 10 };
    style.*.FramePadding = .{ .x = 8, .y = 5 };
    style.*.ItemSpacing = .{ .x = 8, .y = 6 };
    style.*.WindowBorderSize = 0;
    style.*.FrameBorderSize = 0;
    style.*.SeparatorSize = 1;

    // Semi-transparent windows
    style.*.Alpha = 0.97;

    // Colors — dark blue-grey palette
    const colors = &style.*.Colors;
    colors[@intCast(c.ImGuiCol_WindowBg)] = .{ .x = 0.08, .y = 0.08, .z = 0.12, .w = 0.92 };
    colors[@intCast(c.ImGuiCol_ChildBg)] = .{ .x = 0.07, .y = 0.07, .z = 0.10, .w = 0.50 };
    colors[@intCast(c.ImGuiCol_PopupBg)] = .{ .x = 0.08, .y = 0.08, .z = 0.12, .w = 0.95 };
    colors[@intCast(c.ImGuiCol_Border)] = .{ .x = 0.20, .y = 0.20, .z = 0.25, .w = 0.0 };

    colors[@intCast(c.ImGuiCol_FrameBg)] = .{ .x = 0.14, .y = 0.14, .z = 0.20, .w = 1.0 };
    colors[@intCast(c.ImGuiCol_FrameBgHovered)] = .{ .x = 0.22, .y = 0.22, .z = 0.30, .w = 1.0 };
    colors[@intCast(c.ImGuiCol_FrameBgActive)] = .{ .x = 0.28, .y = 0.28, .z = 0.38, .w = 1.0 };

    colors[@intCast(c.ImGuiCol_TitleBg)] = .{ .x = 0.06, .y = 0.06, .z = 0.09, .w = 1.0 };
    colors[@intCast(c.ImGuiCol_TitleBgActive)] = .{ .x = 0.10, .y = 0.10, .z = 0.16, .w = 1.0 };

    colors[@intCast(c.ImGuiCol_Header)] = .{ .x = 0.18, .y = 0.18, .z = 0.25, .w = 1.0 };
    colors[@intCast(c.ImGuiCol_HeaderHovered)] = .{ .x = 0.28, .y = 0.28, .z = 0.38, .w = 1.0 };
    colors[@intCast(c.ImGuiCol_HeaderActive)] = .{ .x = 0.34, .y = 0.34, .z = 0.46, .w = 1.0 };

    // Accent — muted teal
    colors[@intCast(c.ImGuiCol_SliderGrab)] = .{ .x = 0.35, .y = 0.60, .z = 0.65, .w = 1.0 };
    colors[@intCast(c.ImGuiCol_SliderGrabActive)] = .{ .x = 0.45, .y = 0.75, .z = 0.80, .w = 1.0 };
    colors[@intCast(c.ImGuiCol_Button)] = .{ .x = 0.18, .y = 0.30, .z = 0.35, .w = 1.0 };
    colors[@intCast(c.ImGuiCol_ButtonHovered)] = .{ .x = 0.25, .y = 0.42, .z = 0.48, .w = 1.0 };
    colors[@intCast(c.ImGuiCol_ButtonActive)] = .{ .x = 0.32, .y = 0.52, .z = 0.58, .w = 1.0 };
    colors[@intCast(c.ImGuiCol_CheckMark)] = .{ .x = 0.45, .y = 0.75, .z = 0.80, .w = 1.0 };

    colors[@intCast(c.ImGuiCol_Tab)] = .{ .x = 0.12, .y = 0.12, .z = 0.18, .w = 1.0 };
    colors[@intCast(c.ImGuiCol_TabHovered)] = .{ .x = 0.25, .y = 0.42, .z = 0.48, .w = 1.0 };
    colors[@intCast(c.ImGuiCol_TabSelected)] = .{ .x = 0.20, .y = 0.34, .z = 0.40, .w = 1.0 };

    colors[@intCast(c.ImGuiCol_SeparatorHovered)] = .{ .x = 0.35, .y = 0.60, .z = 0.65, .w = 0.78 };
    colors[@intCast(c.ImGuiCol_SeparatorActive)] = .{ .x = 0.35, .y = 0.60, .z = 0.65, .w = 1.0 };
    colors[@intCast(c.ImGuiCol_ResizeGrip)] = .{ .x = 0.35, .y = 0.60, .z = 0.65, .w = 0.20 };
    colors[@intCast(c.ImGuiCol_ResizeGripHovered)] = .{ .x = 0.35, .y = 0.60, .z = 0.65, .w = 0.67 };
    colors[@intCast(c.ImGuiCol_ResizeGripActive)] = .{ .x = 0.35, .y = 0.60, .z = 0.65, .w = 0.95 };

    colors[@intCast(c.ImGuiCol_Text)] = .{ .x = 0.88, .y = 0.88, .z = 0.92, .w = 1.0 };
    colors[@intCast(c.ImGuiCol_TextDisabled)] = .{ .x = 0.45, .y = 0.45, .z = 0.50, .w = 1.0 };

    colors[@intCast(c.ImGuiCol_ScrollbarBg)] = .{ .x = 0.06, .y = 0.06, .z = 0.09, .w = 0.50 };
    colors[@intCast(c.ImGuiCol_ScrollbarGrab)] = .{ .x = 0.22, .y = 0.22, .z = 0.30, .w = 1.0 };
    colors[@intCast(c.ImGuiCol_ScrollbarGrabHovered)] = .{ .x = 0.30, .y = 0.30, .z = 0.40, .w = 1.0 };
    colors[@intCast(c.ImGuiCol_ScrollbarGrabActive)] = .{ .x = 0.38, .y = 0.38, .z = 0.50, .w = 1.0 };
}
