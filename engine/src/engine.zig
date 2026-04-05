// engine.zig — Lunatic engine core. Lifecycle, registries, and public API.

const std = @import("std");
const builtin = @import("builtin");
const math3d = @import("math3d");
const Mat4 = math3d.Mat4;
const ecs = @import("zig-ecs");
const geometry = @import("geometry");
const renderer = @import("renderer");
pub const postprocess = @import("postprocess");
pub const physics = @import("physics");
const lua_api = @import("lua_api");
pub const gltf = @import("gltf");

pub const core_components = @import("core_components");
const lua = @import("lua");
const lc = lua.c;
pub const HandleKind = enum { mesh, material };
pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("cimgui.h");
    @cInclude("cimgui_impl_sdlgpu3.h");
});
const stbi = @cImport({
    @cInclude("stb_image.h");
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
pub const max_lua_systems = 64;
pub const max_zig_systems = 64;
pub const max_systems = max_zig_systems + max_lua_systems;
pub const ZigSystemFn = *const fn (*Engine, f32) void;

pub const SystemKind = enum { zig, lua };

pub const SystemEntry = struct {
    name_buf: [31:0]u8 = .{0} ** 31,
    kind: SystemKind = .zig,
    time_us: u64 = 0,
    // Payload
    zig_fn: ?ZigSystemFn = null,
    lua_ref: c_int = 0,
    disabled: bool = false,

    pub fn name(self: *const SystemEntry) [*:0]const u8 {
        return @ptrCast(&self.name_buf);
    }

    pub fn setName(self: *SystemEntry, src: [*:0]const u8) void {
        const s = std.mem.span(src);
        const len = @min(s.len, 31);
        @memcpy(self.name_buf[0..len], s[0..len]);
        self.name_buf[len] = 0;
    }
};

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
    pub fn deinit(self: *AssetStore, device: *c.SDL_GPUDevice) void {
        for (0..self.texture_count) |i| {
            if (self.texture_registry[i]) |tex| c.SDL_ReleaseGPUTexture(device, tex.texture);
        }
        if (self.default_sampler) |s| c.SDL_ReleaseGPUSampler(device, s);
        for (0..self.mesh_count) |i| {
            if (self.mesh_registry[i]) |mesh| {
                c.SDL_ReleaseGPUBuffer(device, mesh.vertex_buffer);
                if (mesh.index_buffer) |ib| c.SDL_ReleaseGPUBuffer(device, ib);
            }
        }
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
    physics_active: u32 = 0,
    physics_total: u32 = 0,
    // Render sub-timings
    time_prepare_us: u64 = 0, // draw list build + sort
    time_instances_us: u64 = 0, // matrix computation + upload
    time_scene_us: u64 = 0, // scene render pass
    time_postprocess_us: u64 = 0, // DoF + bloom + composite
    time_imgui_us: u64 = 0, // ImGui overlay
};

pub const Engine = struct {
    // ECS
    registry: ecs.Registry,

    // GPU (null when headless)
    gpu_device: ?*c.SDL_GPUDevice = null,
    sdl_window: ?*c.SDL_Window = null,
    pipeline: ?*c.SDL_GPUGraphicsPipeline = null,
    instance_buffer: ?*c.SDL_GPUBuffer = null,
    instance_transfer: ?*c.SDL_GPUTransferBuffer = null,
    instance_capacity: u32 = 0,
    depth_texture: ?*c.SDL_GPUTexture = null,
    msaa_color_texture: ?*c.SDL_GPUTexture = null,
    swapchain_format: c.SDL_GPUTextureFormat = c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM,
    sample_count: SampleCount = .@"1",
    rt_w: u32 = 0,
    rt_h: u32 = 0,

    // Scene
    clear_color: [4]f32 = .{ 0.08, 0.08, 0.12, 1.0 },
    ambient_color: [4]f32 = .{ 0.15, 0.15, 0.2, 0.0 },

    // Post-processing (bloom)
    postprocess: postprocess.PostProcessState = .{},
    physics: physics.PhysicsState = .{},

    // Fog
    fog_enabled: bool = false,
    fog_start: f32 = 10.0,
    fog_end: f32 = 30.0,
    fog_color: [3]f32 = .{ 0.08, 0.08, 0.12 },

    // Asset registries (meshes, materials, textures)
    assets: AssetStore = .{},

    // Draw sorting scratch buffer
    draw_list: [renderer.max_renderables]renderer.DrawEntry = undefined,

    // Frame counter + stats
    current_frame: u64 = 0,
    stats: FrameStats = .{},

    // Live queries (persistent entity sets, managed by lua_api)
    live_queries: [lua_api.max_live_queries]lua_api.LiveQuery = .{lua_api.LiveQuery{}} ** lua_api.max_live_queries,
    live_query_count: u32 = 0,

    // All systems (Zig + Lua, unified, ordered)
    systems: [max_systems]SystemEntry = .{SystemEntry{}} ** max_systems,
    system_count: u32 = 0,

    // Lua
    lua_state: ?*lc.lua_State = null,

    // State
    headless: bool = false,
    debug_stats: bool = false,

    // ---- Lifecycle ----

    /// Initialize the engine: ECS, Lua, GPU device, pipeline, built-in resources.
    /// Must be called on a pointer-stable location (e.g. `var engine: Engine = undefined;`).
    pub fn init(self: *Engine, config: Config) !void {
        self.* = Engine{
            .registry = ecs.Registry.init(std.heap.c_allocator),
            .headless = config.headless,
            .debug_stats = config.debug_stats,
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

    /// Release all GPU resources, Lua state, and ECS storage.
    pub fn deinit(self: *Engine) void {
        for (self.live_queries[0..self.live_query_count]) |*lq| lq.deinit();
        if (self.lua_state) |L| lc.lua_close(L);

        physics.deinitPhysics(self);
        if (self.gpu_device) |_| {
            c.cImGui_ImplSDLGPU3_Shutdown();
            c.cImGui_ImplSDL3_Shutdown();
            c.igDestroyContext(null);
            postprocess.deinitPostProcess(self);
            const device = self.gpu_device.?;
            self.assets.deinit(device);
            if (self.msaa_color_texture) |mt| c.SDL_ReleaseGPUTexture(device, mt);
            if (self.depth_texture) |dt| c.SDL_ReleaseGPUTexture(device, dt);
            if (self.instance_buffer) |b| c.SDL_ReleaseGPUBuffer(device, b);
            if (self.instance_transfer) |t| c.SDL_ReleaseGPUTransferBuffer(device, t);
            if (self.pipeline) |p| c.SDL_ReleaseGPUGraphicsPipeline(device, p);
            if (self.sdl_window) |w| c.SDL_DestroyWindow(w);
            c.SDL_DestroyGPUDevice(device);
            c.SDL_Quit();
        }

        self.registry.deinit();
    }

    /// Load and execute a Lua script file.
    pub fn loadScript(self: *Engine, path: [*:0]const u8) !void {
        const L = self.lua_state.?;
        if (lc.luaL_loadfile(L, path) != 0 or lc.lua_pcall(L, 0, 0, 0) != 0) {
            const err = lc.lua_tolstring(L, -1, null);
            std.debug.print("Lua error: {s}\n", .{err});
            return error.LuaLoadFailed;
        }
    }

    /// Enter the main loop: polls events, runs Lua systems, renders. Returns on quit.
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
                _ = c.cImGui_ImplSDL3_ProcessEvent(&event);
                if (event.type == c.SDL_EVENT_QUIT) running = false;
                if (event.type == c.SDL_EVENT_KEY_DOWN and event.key.scancode == c.SDL_SCANCODE_ESCAPE) running = false;
            }

            // ImGui new frame (before systems so user code can draw UI)
            c.cImGui_ImplSDLGPU3_NewFrame();
            c.cImGui_ImplSDL3_NewFrame();
            c.igNewFrame();

            self.runAllSystems(dt);

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

            // Phase 1: Prepare (draw list build + sort)
            const tp0 = c.SDL_GetPerformanceCounter();
            const frame = renderer.prepareFrame(self, sw_w, sw_h);
            self.stats.entities_rendered = frame.draw_count;
            self.stats.draw_calls = renderer.countBatches(self, frame.draw_count);
            const tp1 = c.SDL_GetPerformanceCounter();
            self.stats.time_prepare_us = (tp1 - tp0) * 1_000_000 / pf;

            const hdr_tex = self.postprocess.hdr_texture.?;

            // Per-camera rendering
            var cam_view = self.registry.view(.{ core_components.Position, core_components.Camera }, .{});
            var cam_iter = cam_view.entityIterator();
            while (cam_iter.next()) |cam_entity| {
                const cam = cam_view.getConst(core_components.Camera, cam_entity);

                // Phase 2: Instance data (matrix computation + GPU upload)
                const ti0 = c.SDL_GetPerformanceCounter();
                renderer.uploadInstanceData(self, cmd, cam_entity, sw_w, sw_h, frame);
                const ti1 = c.SDL_GetPerformanceCounter();
                self.stats.time_instances_us = (ti1 - ti0) * 1_000_000 / pf;

                // Phase 3: Scene render pass
                const ts0 = c.SDL_GetPerformanceCounter();
                renderer.executeScenePass(self, cmd, cam_entity, hdr_tex, sw_w, sw_h, frame, cam.exposure);
                const ts1 = c.SDL_GetPerformanceCounter();
                self.stats.time_scene_us = (ts1 - ts0) * 1_000_000 / pf;

                // Phase 4: Post-process (DoF + bloom + composite)
                const tpp0 = c.SDL_GetPerformanceCounter();
                const settings = postprocess.CameraPostSettings{
                    .exposure = cam.exposure,
                    .bloom_intensity = cam.bloom_intensity,
                    .dof_focus_dist = cam.dof_focus_dist,
                    .dof_focus_range = cam.dof_focus_range,
                    .dof_blur_radius = cam.dof_blur_radius,
                    .vignette_intensity = cam.vignette,
                    .vignette_smoothness = cam.vignette_smoothness,
                    .chromatic_aberration = cam.chromatic_aberration,
                    .grain_intensity = cam.grain,
                    .color_temp = cam.color_temp,
                    .flare_intensity = cam.flare_intensity,
                    .flare_ghost_dispersal = cam.flare_ghost_dispersal,
                    .flare_halo_width = cam.flare_halo_width,
                    .flare_chroma_distortion = cam.flare_chroma_distortion,
                    .flare_starburst = cam.flare_starburst,
                    .flare_dirt_intensity = cam.flare_dirt_intensity,
                    .camera_angle_z = self.registry.getConst(core_components.Rotation, cam_entity).z * (std.math.pi / 180.0),
                };
                postprocess.executePostProcess(self, cmd, swapchain_tex.?, sw_w, sw_h, settings);
                const tpp1 = c.SDL_GetPerformanceCounter();
                self.stats.time_postprocess_us = (tpp1 - tpp0) * 1_000_000 / pf;
            }

            // Phase 5: ImGui overlay
            const tui0 = c.SDL_GetPerformanceCounter();
            c.igRender();
            const draw_data = c.igGetDrawData();
            if (draw_data != null) {
                c.cImGui_ImplSDLGPU3_PrepareDrawData(draw_data, cmd);

                const imgui_color_target = c.SDL_GPUColorTargetInfo{
                    .texture = swapchain_tex,
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

            _ = c.SDL_SubmitGPUCommandBuffer(cmd);

            // Debug stats to console (once per second)
            if (self.debug_stats and self.current_frame % 60 == 0) {
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
            @as(f64, @floatFromInt(s.time_prepare_us)) / 1000.0,
            @as(f64, @floatFromInt(s.time_instances_us)) / 1000.0,
            @as(f64, @floatFromInt(s.time_scene_us)) / 1000.0,
            @as(f64, @floatFromInt(s.time_postprocess_us)) / 1000.0,
            @as(f64, @floatFromInt(s.time_imgui_us)) / 1000.0,
        });

        // Per-system breakdown
        for (self.systems[0..self.system_count]) |sys| {
            if (sys.disabled) continue;
            const kind_label: []const u8 = if (sys.kind == .zig) "zig" else "lua";
            std.debug.print("  {d:.2}ms [{s}] {s}\n", .{
                @as(f64, @floatFromInt(sys.time_us)) / 1000.0,
                kind_label,
                sys.name(),
            });
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

        self.sdl_window = c.SDL_CreateWindow(config.title, @intCast(config.width), @intCast(config.height), c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY);
        if (self.sdl_window == null) {
            std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
            return error.SDLWindowFailed;
        }

        if (!c.SDL_ClaimWindowForGPUDevice(self.gpu_device.?, self.sdl_window)) {
            std.debug.print("SDL_ClaimWindowForGPUDevice failed: {s}\n", .{c.SDL_GetError()});
            return error.ClaimWindowFailed;
        }

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

        // Instance buffer for batched rendering
        const instance_buf_size: u32 = renderer.max_renderables * @sizeOf(renderer.InstanceData);
        self.instance_buffer = c.SDL_CreateGPUBuffer(self.gpu_device.?, &c.SDL_GPUBufferCreateInfo{
            .usage = c.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ,
            .size = instance_buf_size,
            .props = 0,
        }) orelse return error.BufferFailed;
        self.instance_transfer = c.SDL_CreateGPUTransferBuffer(self.gpu_device.?, &c.SDL_GPUTransferBufferCreateInfo{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = instance_buf_size,
            .props = 0,
        }) orelse return error.BufferFailed;
        self.instance_capacity = renderer.max_renderables;

        // Post-processing (bloom)
        try postprocess.initPostProcess(self);

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

        // Built-in systems
        self.addSystem("age", &Engine.ageSystem);
        self.addSystem("physics", &physics.physicsSystem);
        self.addSystem("fly_camera", &Engine.flyCameraSystem);
        self.addSystem("stats_overlay", &Engine.statsOverlaySystem);
    }

    // ---- Mesh API ----

    /// Upload vertex (and optional index) data to the GPU. Returns a mesh handle.
    /// Pass a name for built-in meshes (accessible via `lunatic.mesh.*` in Lua), or null.
    pub fn createMesh(self: *Engine, name: ?[*:0]const u8, vertices: []const Vertex, indices: ?[]const u32) !u32 {
        if (self.assets.mesh_count >= max_meshes) return error.TooManyMeshes;
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

        const id = self.assets.mesh_count;
        self.assets.mesh_registry[id] = .{
            .vertex_buffer = vbuf,
            .vertex_count = @intCast(vertices.len),
            .index_buffer = ibuf,
            .index_count = icount,
        };
        self.assets.mesh_names[id] = name;
        self.assets.mesh_count += 1;
        return id;
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

    /// Create a material with an optional name (accessible via `lunatic.material.*` in Lua).
    pub fn createNamedMaterial(self: *Engine, name: ?[*:0]const u8, data: MaterialData) !u32 {
        if (self.assets.material_count >= max_materials) return error.TooManyMaterials;
        const id = self.assets.material_count;
        self.assets.material_registry[id] = data;
        self.assets.material_names[id] = name;
        self.assets.material_count += 1;
        return id;
    }

    /// Look up a named material by string. Returns the handle or null.
    pub fn findMaterial(self: *Engine, name: [*:0]const u8) ?u32 {
        return self.assets.findMaterial(name);
    }

    /// Resolve a Lua argument to an asset handle ID. Accepts either a numeric ID
    /// or a string name (e.g. "cube", "default") that gets looked up in the registry.
    pub fn resolveHandle(self: *Engine, L: ?*lc.lua_State, idx: c_int, kind: HandleKind) u32 {
        if (lc.lua_type(L, idx) == lc.LUA_TNUMBER) {
            return @intCast(lc.lua_tointeger(L, idx));
        }
        const name = lc.luaL_checklstring(L, idx, null);
        const id = switch (kind) {
            .mesh => self.assets.findMesh(name),
            .material => self.assets.findMaterial(name),
        };
        if (id) |found| return found;
        const label = switch (kind) {
            .mesh => "unknown mesh: %s",
            .material => "unknown material: %s",
        };
        _ = lc.luaL_error(L, label, name);
        unreachable;
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

    // ---- Lua systems ----

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

    // ---- Zig systems ----

    /// Register a named Zig system function.
    pub fn addSystem(self: *Engine, name: [*:0]const u8, func: ZigSystemFn) void {
        if (self.system_count >= max_systems) return;
        self.systems[self.system_count] = .{ .kind = .zig, .zig_fn = func };
        self.systems[self.system_count].setName(name);
        self.system_count += 1;
    }

    /// Register a Lua system (called from lua_api).
    pub fn addLuaSystem(self: *Engine, name: [*:0]const u8, lua_ref: c_int) void {
        if (self.system_count >= max_systems) return;
        self.systems[self.system_count] = .{ .kind = .lua, .lua_ref = lua_ref };
        self.systems[self.system_count].setName(name);
        self.system_count += 1;
    }

    pub fn runAllSystems(self: *Engine, dt: f32) void {
        const L = self.lua_state;
        const perf_freq = c.SDL_GetPerformanceFrequency();

        for (self.systems[0..self.system_count]) |*sys| {
            if (sys.disabled) continue;
            const t_start = c.SDL_GetPerformanceCounter();

            switch (sys.kind) {
                .zig => {
                    if (sys.zig_fn) |func| func(self, dt);
                },
                .lua => {
                    if (L) |state| {
                        lc.lua_rawgeti(state, lc.LUA_REGISTRYINDEX, sys.lua_ref);
                        lc.lua_pushnumber(state, dt);
                        if (lc.lua_pcall(state, 1, 0, 0) != 0) {
                            const err = lc.lua_tolstring(state, -1, null);
                            std.debug.print("Lua system '{s}' error: {s}\n", .{ sys.name(), err });
                            lc.lua_pop(state, 1);
                            sys.disabled = true;
                        }
                    }
                },
            }

            const t_end = c.SDL_GetPerformanceCounter();
            sys.time_us = (t_end - t_start) * 1_000_000 / perf_freq;
        }
    }

    // ---- Built-in systems ----

    /// Built-in stats overlay — top-right corner, always visible.
    pub fn statsOverlaySystem(self: *Engine, _: f32) void {
        const s = self.stats;
        const io = c.igGetIO();
        const display_w: f32 = if (io) |i| i.*.DisplaySize.x else 800;

        c.igSetNextWindowPosEx(.{ .x = display_w - 16, .y = 16 }, c.ImGuiCond_Always, .{ .x = 1, .y = 0 });
        _ = c.igBegin("##stats", null, c.ImGuiWindowFlags_NoTitleBar | c.ImGuiWindowFlags_NoResize | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_AlwaysAutoResize | c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoFocusOnAppearing | c.ImGuiWindowFlags_NoNav);

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

        c.igSeparatorText("Systems");

        for (self.systems[0..self.system_count]) |*sys| {
            if (sys.disabled) continue;
            const kind_label: [*:0]const u8 = if (sys.kind == .zig) "zig" else "lua";
            var sys_buf: [128]u8 = undefined;
            const sys_line = std.fmt.bufPrintZ(&sys_buf, "{d:.2}ms [{s}] {s}", .{
                @as(f64, @floatFromInt(sys.time_us)) / 1000.0,
                kind_label,
                sys.name(),
            }) catch "???";
            c.igTextUnformatted(sys_line);
        }

        // Render sub-phases
        c.igSeparatorText("Render");

        const render_phases = [_]struct { name: []const u8, us: u64 }{
            .{ .name = "prepare", .us = s.time_prepare_us },
            .{ .name = "instances", .us = s.time_instances_us },
            .{ .name = "scene", .us = s.time_scene_us },
            .{ .name = "postprocess", .us = s.time_postprocess_us },
            .{ .name = "imgui", .us = s.time_imgui_us },
        };

        for (render_phases) |phase| {
            var phase_buf: [128]u8 = undefined;
            const phase_line = std.fmt.bufPrintZ(&phase_buf, "{d:.2}ms {s}", .{
                @as(f64, @floatFromInt(phase.us)) / 1000.0,
                phase.name,
            }) catch "???";
            c.igTextUnformatted(phase_line);
        }

        c.igEnd();
    }

    /// Increment Age.seconds for all entities with the Age component.
    pub fn ageSystem(self: *Engine, dt: f32) void {
        var view = self.registry.view(.{core_components.Age}, .{});
        var iter = view.entityIterator();
        while (iter.next()) |entity| {
            var age = view.get(entity);
            age.seconds += dt;
        }
    }

    /// FPS-style fly camera. Processes entities with FlyCamera + Position + Rotation.
    /// Right-click activates (hides cursor + enables look/move), release to interact with UI.
    pub fn flyCameraSystem(self: *Engine, dt: f32) void {
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

        var view = self.registry.view(.{ core_components.Position, core_components.Rotation, core_components.FlyCamera }, .{});
        var iter = view.entityIterator();
        while (iter.next()) |entity| {
            var pos = view.get(core_components.Position, entity);
            var rot = view.get(core_components.Rotation, entity);
            const fly = view.getConst(core_components.FlyCamera, entity);

            if (!rmb_held) continue;

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

            const speed: f32 = if (self.isKeyDown(c.SDL_SCANCODE_LSHIFT)) fly.fast_speed else fly.speed;
            if (self.isKeyDown(c.SDL_SCANCODE_W)) { pos.x += fx * speed * dt; pos.y += fy * speed * dt; pos.z += fz * speed * dt; }
            if (self.isKeyDown(c.SDL_SCANCODE_S)) { pos.x -= fx * speed * dt; pos.y -= fy * speed * dt; pos.z -= fz * speed * dt; }
            if (self.isKeyDown(c.SDL_SCANCODE_A)) { pos.x -= rx * speed * dt; pos.y -= ry * speed * dt; pos.z -= rz * speed * dt; }
            if (self.isKeyDown(c.SDL_SCANCODE_D)) { pos.x += rx * speed * dt; pos.y += ry * speed * dt; pos.z += rz * speed * dt; }
            if (self.isKeyDown(c.SDL_SCANCODE_SPACE)) pos.y += speed * dt;
            if (self.isKeyDown(c.SDL_SCANCODE_LCTRL)) pos.y -= speed * dt;
        }
    }

    /// Unregister all systems and free Lua registry references.
    pub fn resetSystems(self: *Engine) void {
        if (self.lua_state) |L| {
            for (self.systems[0..self.system_count]) |sys| {
                if (sys.kind == .lua and sys.lua_ref != 0) {
                    lc.luaL_unref(L, lc.LUA_REGISTRYINDEX, sys.lua_ref);
                }
            }
        }
        self.system_count = 0;
        self.systems = .{SystemEntry{}} ** max_systems;
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
