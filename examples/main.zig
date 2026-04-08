// Lunatic — example scene manager with shared debug UI.
//
// Right-click + drag to look around, WASD to move, Space/Ctrl for up/down.
// Shift for fast movement. Use the Debug window to switch scenes and tweak
// post-processing settings.

const std = @import("std");
const engine_mod = @import("engine");
const Engine = engine_mod.Engine;
const ecs = engine_mod.ecs;
const core = engine_mod.core_components;
const c = engine_mod.c;

const PhysicsRain = @import("scene_physics_rain");
const LightingGallery = @import("scene_lighting_gallery");
const MaterialShowcase = @import("scene_material_showcase");

// ============================================================
// Scene registry
// ============================================================

const SceneIndex = enum(u8) {
    physics_rain = 0,
    lighting_gallery = 1,
    material_showcase = 2,
};

const scene_names = [_][*:0]const u8{
    "Physics Rain",
    "Lighting Gallery",
    "Material Showcase",
};

const scene_count = scene_names.len;

// ============================================================
// State
// ============================================================

var current_scene: ?SceneIndex = null;
var cam: ecs.entity_t = 0;

// Scene instances (one of each, reused across loads)
var physics_rain: PhysicsRain = .{};
var lighting_gallery: LightingGallery = .{};
var material_showcase: MaterialShowcase = .{};

// ============================================================
// Scene switching
// ============================================================

fn cleanupCurrentScene(engine: *Engine) void {
    if (current_scene) |scene| {
        switch (scene) {
            .physics_rain => physics_rain.cleanup(engine),
            .lighting_gallery => lighting_gallery.cleanup(engine),
            .material_showcase => material_showcase.cleanup(engine),
        }
        current_scene = null;
    }
}

fn loadScene(engine: *Engine, index: SceneIndex) void {
    cleanupCurrentScene(engine);
    switch (index) {
        .physics_rain => physics_rain.setup(engine, cam),
        .lighting_gallery => lighting_gallery.setup(engine, cam),
        .material_showcase => material_showcase.setup(engine, cam),
    }
    current_scene = index;
}

// ============================================================
// Systems
// ============================================================

fn sceneUpdateSystem(engine: *Engine, dt: f32) void {
    if (current_scene) |scene| {
        switch (scene) {
            .physics_rain => physics_rain.update(engine, dt),
            .lighting_gallery => lighting_gallery.update(engine, dt),
            .material_showcase => material_showcase.update(engine, dt),
        }
    }
}

fn debugUiSystem(engine: *Engine, _: f32) void {
    c.igSetNextWindowPos(.{ .x = 16, .y = 16 }, c.ImGuiCond_FirstUseEver);
    c.igSetNextWindowSize(.{ .x = 280, .y = 0 }, c.ImGuiCond_FirstUseEver);
    if (!c.igBegin("Debug", null, 0)) {
        c.igEnd();
        return;
    }

    // Scene selector
    c.igSeparatorText("Scene");
    for (scene_names, 0..) |scene_name, i| {
        const is_current = if (current_scene) |cs| @intFromEnum(cs) == i else false;
        // Highlight current scene with a bullet
        if (is_current) {
            c.igBullet();
            c.igSameLine();
        }
        c.igPushIDInt(@intCast(i));
        if (c.igButton(scene_name) and !is_current) {
            loadScene(engine, @enumFromInt(i));
        }
        c.igPopID();
    }

    // Post-processing controls
    if (ecs.get_mut(engine.world, cam, core.Camera)) |cam_ref| {
        if (c.igCollapsingHeaderBoolPtr("Post-Processing", null, 0)) {
            _ = c.igSliderFloat("Exposure", &cam_ref.exposure, 0.1, 5.0);
            _ = c.igSliderFloat("Bloom Intensity", &cam_ref.bloom_intensity, 0.0, 1.0);
        }

        if (c.igCollapsingHeaderBoolPtr("Depth of Field", null, 0)) {
            _ = c.igSliderFloat("Focus Distance", &cam_ref.dof_focus_dist, 0, 50);
            _ = c.igSliderFloat("Focus Range", &cam_ref.dof_focus_range, 0.5, 30);
            _ = c.igSliderFloat("Blur Radius", &cam_ref.dof_blur_radius, 1, 60);
        }

        if (c.igCollapsingHeaderBoolPtr("Reflections (SSR)", null, 0)) {
            _ = c.igSliderFloat("Intensity", &cam_ref.ssr_intensity, 0, 1.0);
            _ = c.igSliderFloat("Max Distance", &cam_ref.ssr_max_distance, 5, 100);
            _ = c.igSliderFloat("Stride (px)", &cam_ref.ssr_stride, 1, 16);
            _ = c.igSliderFloat("Thickness", &cam_ref.ssr_thickness, 0.01, 1.0);
        }

        if (c.igCollapsingHeaderBoolPtr("Lens Effects", null, 0)) {
            _ = c.igSliderFloat("Vignette", &cam_ref.vignette, 0, 1);
            _ = c.igSliderFloat("Vignette Smoothness", &cam_ref.vignette_smoothness, 0.2, 0.8);
            _ = c.igSliderFloat("Chromatic Aberration", &cam_ref.chromatic_aberration, 0, 3);
            _ = c.igSliderFloat("Film Grain", &cam_ref.grain, 0, 0.2);
            _ = c.igSliderFloat("Color Temperature", &cam_ref.color_temp, -3, 3);
        }

        if (c.igCollapsingHeaderBoolPtr("Lens Flare", null, 0)) {
            _ = c.igSliderFloat("Flare Intensity", &cam_ref.flare_intensity, 0, 3);
            _ = c.igSliderFloat("Ghost Dispersal", &cam_ref.flare_ghost_dispersal, 0.1, 1.0);
            _ = c.igSliderFloat("Halo Width", &cam_ref.flare_halo_width, 0.1, 0.9);
            _ = c.igSliderFloat("Chroma Distortion", &cam_ref.flare_chroma_distortion, 0, 0.02);
            _ = c.igSliderFloat("Lens Dirt", &cam_ref.flare_dirt_intensity, 0, 1);
        }
    }

    if (c.igCollapsingHeaderBoolPtr("Bloom Shape", null, 0)) {
        _ = c.igSliderFloat("Radius", &engine.postprocess.radius, 0.5, 3.0);
        _ = c.igSliderFloat("1/2 (core)", &engine.postprocess.tints[0], 0, 1);
        _ = c.igSliderFloat("1/4", &engine.postprocess.tints[1], 0, 1);
        _ = c.igSliderFloat("1/8", &engine.postprocess.tints[2], 0, 1);
        _ = c.igSliderFloat("1/16", &engine.postprocess.tints[3], 0, 1);
        _ = c.igSliderFloat("1/32", &engine.postprocess.tints[4], 0, 1);
        _ = c.igSliderFloat("1/64 (haze)", &engine.postprocess.tints[5], 0, 1);
    }

    if (c.igCollapsingHeaderBoolPtr("Volumetric Fog", null, 0)) {
        _ = c.igSliderFloat("Density", &engine.vol_fog_density, 0, 0.3);
        _ = c.igSliderFloat("Height Falloff", &engine.vol_fog_height_falloff, 0, 2.0);
        _ = c.igSliderFloat("Anisotropy (g)", &engine.vol_fog_anisotropy, -0.5, 0.95);
        _ = c.igSliderFloat("Scattering", &engine.vol_fog_scattering, 0.01, 0.5);
        c.igSeparatorText("Light Shadows");
        _ = c.igSliderFloat("Shadow Steps", &engine.vol_fog_shadow_steps, 0, 8);
        _ = c.igSliderFloat("Shadow Softness", &engine.vol_fog_shadow_softness, 0.5, 10.0);
        engine.vol_fog_enabled = engine.vol_fog_density > 0.001;
    }

    c.igEnd();
}

// ============================================================
// Entry point
// ============================================================

pub fn main() !void {
    var debug = false;
    var args = std.process.args();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--debug")) debug = true;
    }

    var engine: Engine = undefined;
    try engine.init(.{ .width = 1280, .height = 720, .debug_stats = debug });

    // Shared camera (persists across scene switches)
    cam = ecs.new_id(engine.world);
    _ = ecs.set(engine.world, cam, core.Position, .{ .x = 0, .y = 8, .z = 12 });
    _ = ecs.set(engine.world, cam, core.Rotation, .{ .x = 34, .y = 0, .z = 0 });
    _ = ecs.set(engine.world, cam, core.Camera, .{
        .exposure = 0.8,
        .bloom_intensity = 0.5,
        .vignette = 0.4,
        .vignette_smoothness = 0.5,
        .chromatic_aberration = 0.08,
        .grain = 0.03,
        .flare_intensity = 0.15,
    });
    _ = ecs.set(engine.world, cam, core.FlyCamera, .{});

    // Register systems
    engine.addSystem("scene_update", sceneUpdateSystem, ecs.OnUpdate);
    engine.addSystem("debug_ui", debugUiSystem, ecs.OnUpdate);

    // Auto-discover and register all Lua systems in the systems directory.
    // Each .lua file declares its own component terms — no Zig registration needed.
    engine.loadLuaSystems("examples/systems");

    // Load the first scene
    loadScene(&engine, .physics_rain);

    try engine.run();

    cleanupCurrentScene(&engine);
    engine.deinit();
    std.process.exit(0);
}
