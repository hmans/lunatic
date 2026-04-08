// Lighting Gallery — dark room showcasing clustered point and spot lights.
//
// Demonstrates: Lua-driven orbit system for point lights, bobbing center
// sphere, pulsing light intensity — all animated by hot-reloadable Lua systems.

const std = @import("std");
const engine_mod = @import("engine");
const Engine = engine_mod.Engine;
const ecs = engine_mod.ecs;
const core = engine_mod.core_components;
const ex = engine_mod.components;

pub const name = "Lighting Gallery";

entities: [64]ecs.entity_t = .{0} ** 64,
entity_count: u32 = 0,
materials: [8]u32 = .{0} ** 8,
material_count: u32 = 0,

const Self = @This();

pub fn setup(self: *Self, engine: *Engine, cam: ecs.entity_t) void {
    self.* = .{};

    // Dark scene, no fog
    engine.clear_color = .{ 0.02, 0.02, 0.04, 1.0 };
    engine.ambient_color = .{ 0.02, 0.02, 0.03, 0.0 };
    engine.fog_enabled = false;

    // Camera
    if (ecs.get_mut(engine.world, cam, core.Position)) |pos| {
        pos.* = .{ .x = 0, .y = 6, .z = 14 };
    }
    if (ecs.get_mut(engine.world, cam, core.Rotation)) |rot| {
        rot.* = .{ .x = 20, .y = 0, .z = 0 };
    }

    // Dim directional (moonlight)
    const light = self.track(engine);
    _ = ecs.set(engine.world, light, core.DirectionalLight, .{
        .dir_x = 0.2, .dir_y = 0.8, .dir_z = 0.3,
        .r = 0.15, .g = 0.15, .b = 0.2,
    });

    // Floor
    const floor_mat = self.trackMat(engine, engine.createMaterial(.{ .albedo = .{ 0.4, 0.4, 0.42, 1.0 }, .roughness = 0.7 }) catch 0);
    const floor = self.track(engine);
    _ = ecs.set(engine.world, floor, core.Position, .{ .x = 0, .y = -0.25, .z = 0 });
    _ = ecs.set(engine.world, floor, core.MeshHandle, .{ .id = engine.findMesh("cube") orelse 0 });
    _ = ecs.set(engine.world, floor, core.MaterialHandle, .{ .id = floor_mat });
    _ = ecs.set(engine.world, floor, core.Scale, .{ .x = 30, .y = 0.5, .z = 30 });
    _ = ecs.set(engine.world, floor, core.Rotation, .{});
    ecs.add(engine.world, floor, core.ShadowCaster);
    ecs.add(engine.world, floor, core.ShadowReceiver);

    // Pillars in a hexagonal ring
    const pillar_mat = self.trackMat(engine, engine.createMaterial(.{ .albedo = .{ 0.6, 0.6, 0.65, 1.0 }, .roughness = 0.3, .metallic = 0.1 }) catch 0);
    for (0..6) |i| {
        const angle: f32 = @as(f32, @floatFromInt(i)) * std.math.pi * 2.0 / 6.0;
        const x = @cos(angle) * 6.0;
        const z = @sin(angle) * 6.0;
        const pillar = self.track(engine);
        _ = ecs.set(engine.world, pillar, core.Position, .{ .x = x, .y = 1.5, .z = z });
        _ = ecs.set(engine.world, pillar, core.MeshHandle, .{ .id = engine.findMesh("cube") orelse 0 });
        _ = ecs.set(engine.world, pillar, core.MaterialHandle, .{ .id = pillar_mat });
        _ = ecs.set(engine.world, pillar, core.Scale, .{ .x = 0.6, .y = 3, .z = 0.6 });
        _ = ecs.set(engine.world, pillar, core.Rotation, .{});
        ecs.add(engine.world, pillar, core.ShadowCaster);
        ecs.add(engine.world, pillar, core.ShadowReceiver);
    }

    // Center sphere (chrome, reflective) — bobs up and down via Lua
    const chrome = self.trackMat(engine, engine.createMaterial(.{ .albedo = .{ 0.95, 0.95, 0.97, 1.0 }, .metallic = 1.0, .roughness = 0.05 }) catch 0);
    const center = self.track(engine);
    _ = ecs.set(engine.world, center, core.Position, .{ .x = 0, .y = 1.5, .z = 0 });
    _ = ecs.set(engine.world, center, core.MeshHandle, .{ .id = engine.findMesh("sphere") orelse 0 });
    _ = ecs.set(engine.world, center, core.MaterialHandle, .{ .id = chrome });
    _ = ecs.set(engine.world, center, core.Scale, .{ .x = 2, .y = 2, .z = 2 });
    _ = ecs.set(engine.world, center, core.Rotation, .{});
    ecs.add(engine.world, center, core.ShadowCaster);
    ecs.add(engine.world, center, core.ShadowReceiver);
    _ = ecs.set(engine.world, center, ex.Spin, .{ .speed = 15 });
    _ = ecs.set(engine.world, center, ex.Bob, .{ .amplitude = 0.4, .speed = 1.5, .base_y = 1.5 });

    // Ring of colored point lights — animated by Lua orbit + pulse systems
    const colors = [_][3]f32{
        .{ 1.0, 0.2, 0.05 }, // red-orange
        .{ 1.0, 0.6, 0.0 }, // amber
        .{ 0.2, 1.0, 0.1 }, // green
        .{ 0.0, 0.8, 1.0 }, // cyan
        .{ 0.2, 0.3, 1.0 }, // blue
        .{ 0.8, 0.1, 1.0 }, // purple
        .{ 1.0, 0.1, 0.5 }, // magenta
        .{ 1.0, 0.9, 0.3 }, // warm yellow
    };
    for (colors, 0..) |col, i| {
        const fi: f32 = @floatFromInt(i);
        const angle: f32 = fi * std.math.pi * 2.0 / @as(f32, @floatFromInt(colors.len));
        const pl = self.track(engine);
        _ = ecs.set(engine.world, pl, core.Position, .{ .x = 0, .y = 1.5, .z = 0 });
        _ = ecs.set(engine.world, pl, core.PointLight, .{
            .radius = 10, .r = col[0], .g = col[1], .b = col[2], .intensity = 4.0,
        });
        // Orbit driven by Lua — each light starts at a different angle
        _ = ecs.set(engine.world, pl, ex.Orbit, .{
            .radius = 9,
            .speed = 0.3,
            .base_angle = angle,
            .center_y = 1.5,
            .bob_amplitude = 1.0,
            .bob_speed = 2.0,
        });
        // Pulse intensity for a breathing effect (staggered phases)
        _ = ecs.set(engine.world, pl, ex.PulseLight, .{
            .base_intensity = 4.0,
            .amplitude = 2.0,
            .speed = 1.5,
            .phase = fi * 0.8,
        });
    }

    // Overhead spot lights (warm and cool)
    const spot_configs = [_]struct { x: f32, z: f32, r: f32, g: f32, b: f32 }{
        .{ .x = -5, .z = -5, .r = 1.0, .g = 0.8, .b = 0.5 },
        .{ .x = 5, .z = 5, .r = 0.5, .g = 0.7, .b = 1.0 },
    };
    for (spot_configs) |s| {
        const e = self.track(engine);
        _ = ecs.set(engine.world, e, core.Position, .{ .x = s.x, .y = 8, .z = s.z });
        _ = ecs.set(engine.world, e, core.SpotLight, .{
            .radius = 14, .r = s.r, .g = s.g, .b = s.b, .intensity = 6.0,
            .dir_x = 0, .dir_y = -1, .dir_z = 0, .inner_cone = 25, .outer_cone = 40,
        });
    }
}

pub fn update(_: *Self, _: *Engine, _: f32) void {
    // All animation is driven by Lua systems (orbit, bob, pulse_light).
}

pub fn cleanup(self: *Self, engine: *Engine) void {
    for (self.entities[0..self.entity_count]) |e| {
        if (e != 0) ecs.delete(engine.world, e);
    }
    for (self.materials[0..self.material_count]) |m| {
        engine.destroyMaterial(m);
    }
}

fn track(self: *Self, engine: *Engine) ecs.entity_t {
    const e = ecs.new_id(engine.world);
    if (self.entity_count < self.entities.len) {
        self.entities[self.entity_count] = e;
        self.entity_count += 1;
    }
    return e;
}

fn trackMat(self: *Self, _: *Engine, id: u32) u32 {
    if (self.material_count < self.materials.len) {
        self.materials[self.material_count] = id;
        self.material_count += 1;
    }
    return id;
}
