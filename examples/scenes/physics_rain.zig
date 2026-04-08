// Physics Rain — spheres raining down with physics, point lights, and a spot light.
//
// Demonstrates: physics simulation, dynamic entity spawning/recycling,
// point lights, spot lights, shadow casting, multiple materials.

const std = @import("std");
const engine_mod = @import("engine");
const Engine = engine_mod.Engine;
const ecs = engine_mod.ecs;
const core = engine_mod.core_components;
const physics = engine_mod.physics;
const ex = engine_mod.components;

pub const name = "Physics Rain";

const max_bodies = 500;

/// Tracked entities and materials for cleanup.
entities: [64]ecs.entity_t = .{0} ** 64,
entity_count: u32 = 0,
materials: [8]u32 = .{0} ** 8,
material_count: u32 = 0,

/// Ring buffer of physics bodies.
body_ring: [max_bodies]ecs.entity_t = .{0} ** max_bodies,
ring_head: u32 = 0,

/// Spawner state.
spawn_timer: f32 = 0,
spawn_interval: f32 = 0.05,
spawner_active: bool = true,

/// Material handles for spawned objects.
mat_white: u32 = 0,
mat_ember: u32 = 0,
mat_matte: u32 = 0,
mat_silver: u32 = 0,

/// PRNG for randomized spawning.
rng: std.Random.Xoshiro256 = std.Random.Xoshiro256.init(0x12345678),

const Self = @This();

pub fn setup(self: *Self, engine: *Engine, cam: ecs.entity_t) void {
    self.* = .{};
    self.rng = std.Random.Xoshiro256.init(@intCast(std.time.milliTimestamp() & 0xFFFFFFFF));

    // Scene settings
    engine.clear_color = .{ 0.02, 0.02, 0.04, 1.0 };
    engine.ambient_color = .{ 0.03, 0.03, 0.05, 0.0 };
    engine.fog_enabled = true;
    engine.fog_start = 20;
    engine.fog_end = 60;
    engine.fog_color = .{ 0.02, 0.02, 0.04 };

    // Camera position
    if (ecs.get_mut(engine.world, cam, core.Position)) |pos| {
        pos.* = .{ .x = 0, .y = 8, .z = 12 };
    }
    if (ecs.get_mut(engine.world, cam, core.Rotation)) |rot| {
        rot.* = .{ .x = 34, .y = 0, .z = 0 };
    }

    // Directional light
    const light = self.track(engine);
    _ = ecs.set(engine.world, light, core.DirectionalLight, .{
        .dir_x = 0.3,
        .dir_y = 0.8,
        .dir_z = 0.5,
        .r = 0.4,
        .g = 0.38,
        .b = 0.35,
    });

    // Point lights in a ring
    const light_colors = [_][3]f32{
        .{ 1.0, 0.3, 0.1 },
        .{ 0.1, 0.5, 1.0 },
        .{ 0.1, 1.0, 0.3 },
        .{ 1.0, 0.1, 0.8 },
    };
    for (0..8) |i| {
        const fi: f32 = @floatFromInt(i);
        const angle: f32 = fi * std.math.pi * 2.0 / 8.0;
        const x = @cos(angle) * 8.0;
        const z = @sin(angle) * 8.0;
        const col = light_colors[i % light_colors.len];
        const pl = self.track(engine);
        _ = ecs.set(engine.world, pl, core.Position, .{ .x = x, .y = 3, .z = z });
        _ = ecs.set(engine.world, pl, core.PointLight, .{ .radius = 14, .r = col[0], .g = col[1], .b = col[2], .intensity = 8.0 });
        // Pulse intensity via Lua (staggered phases for a wave effect)
        _ = ecs.set(engine.world, pl, ex.PulseLight, .{
            .base_intensity = 8.0,
            .amplitude = 4.0,
            .speed = 2.0,
            .phase = fi * 0.7,
        });
    }

    // Spot light — bobs up and down via Lua
    const spot = self.track(engine);
    _ = ecs.set(engine.world, spot, core.Position, .{ .x = 0, .y = 12, .z = 0 });
    _ = ecs.set(engine.world, spot, ex.Bob, .{ .amplitude = 2, .speed = 0.5, .base_y = 12 });
    _ = ecs.set(engine.world, spot, core.SpotLight, .{
        .radius = 18,
        .r = 1.0,
        .g = 0.9,
        .b = 0.7,
        .intensity = 5.0,
        .dir_x = 0,
        .dir_y = -1,
        .dir_z = 0,
        .inner_cone = 20,
        .outer_cone = 35,
    });

    // Materials
    self.mat_white = self.trackMat(engine, engine.createMaterial(.{ .albedo = .{ 0.85, 0.85, 0.85, 1.0 } }) catch 0);
    self.mat_ember = self.trackMat(engine, engine.createMaterial(.{ .albedo = .{ 1, 0.4, 0.05, 1.0 }, .emissive = .{ 40, 12, 1 } }) catch 0);
    self.mat_matte = self.trackMat(engine, engine.createMaterial(.{ .albedo = .{ 0.05, 0.05, 0.05, 1.0 }, .roughness = 1.0 }) catch 0);
    self.mat_silver = self.trackMat(engine, engine.createMaterial(.{ .albedo = .{ 0.9, 0.9, 0.92, 1.0 }, .metallic = 1.0, .roughness = 0.15 }) catch 0);
    const floor_mat = self.trackMat(engine, engine.createMaterial(.{ .albedo = .{ 0.15, 0.15, 0.17, 1.0 }, .roughness = 0.85 }) catch 0);

    // Floor
    const floor = self.track(engine);
    _ = ecs.set(engine.world, floor, core.Position, .{ .x = 0, .y = -0.25, .z = 0 });
    _ = ecs.set(engine.world, floor, core.MeshHandle, .{ .id = engine.findMesh("cube") orelse 0 });
    _ = ecs.set(engine.world, floor, core.MaterialHandle, .{ .id = floor_mat });
    _ = ecs.set(engine.world, floor, core.Scale, .{ .x = 20, .y = 0.5, .z = 20 });
    _ = ecs.set(engine.world, floor, core.Rotation, .{});
    ecs.add(engine.world, floor, core.ShadowCaster);
    ecs.add(engine.world, floor, core.ShadowReceiver);
    physics.addPhysicsBox(engine, floor, 10, 0.25, 10, .static, 0, 0.2);
    physics.optimizeBroadPhase(engine);
}

pub fn update(self: *Self, engine: *Engine, dt: f32) void {
    if (!self.spawner_active) return;

    self.spawn_timer += dt;
    while (self.spawn_timer >= self.spawn_interval) {
        self.spawnPhysicsObject(engine);
        self.spawn_timer -= self.spawn_interval;
    }

    // Destroy entities that fell off the world
    for (&self.body_ring) |*slot| {
        if (slot.* != 0) {
            if (ecs.get(engine.world, slot.*, core.Position)) |pos| {
                if (pos.y < -20) {
                    ecs.delete(engine.world, slot.*);
                    slot.* = 0;
                }
            }
        }
    }
}

pub fn cleanup(self: *Self, engine: *Engine) void {
    self.spawner_active = false;
    // Jolt bodies are cleaned up automatically by the OnRemove observer
    // when entities lose their RigidBody component (including on delete).
    for (&self.entities) |e| {
        if (e != 0) ecs.delete(engine.world, e);
    }
    for (&self.body_ring) |*slot| {
        if (slot.* != 0) {
            ecs.delete(engine.world, slot.*);
            slot.* = 0;
        }
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

fn spawnPhysicsObject(self: *Self, engine: *Engine) void {
    // Destroy whatever was in this ring slot (Jolt body cleaned up by OnRemove observer)
    if (self.body_ring[self.ring_head] != 0) {
        ecs.delete(engine.world, self.body_ring[self.ring_head]);
    }

    const random = self.rng.random();
    const e = ecs.new_id(engine.world);
    const x = (random.float(f32) - 0.5) * 2.0;
    const z = (random.float(f32) - 0.5) * 2.0;
    const y = 12.0 + random.float(f32) * 8.0;
    _ = ecs.set(engine.world, e, core.Position, .{ .x = x, .y = y, .z = z });
    _ = ecs.set(engine.world, e, core.Rotation, .{
        .x = random.float(f32) * 360.0,
        .y = random.float(f32) * 360.0,
        .z = 0,
    });

    const scale = 0.2 + random.float(f32) * 0.6;
    _ = ecs.set(engine.world, e, core.Scale, .{ .x = scale, .y = scale, .z = scale });
    _ = ecs.set(engine.world, e, core.MeshHandle, .{ .id = engine.findMesh("sphere") orelse 0 });

    // Pick material: 10% chance ember, otherwise random common
    const mat = if (random.float(f32) < 0.1)
        self.mat_ember
    else switch (random.intRangeAtMost(u32, 0, 2)) {
        0 => self.mat_white,
        1 => self.mat_matte,
        else => self.mat_silver,
    };
    _ = ecs.set(engine.world, e, core.MaterialHandle, .{ .id = mat });
    ecs.add(engine.world, e, core.ShadowCaster);
    ecs.add(engine.world, e, core.ShadowReceiver);
    physics.addPhysicsSphere(engine, e, scale * 0.5, .dynamic, 0.3, 1.5);

    self.body_ring[self.ring_head] = e;
    self.ring_head = (self.ring_head + 1) % max_bodies;
}
