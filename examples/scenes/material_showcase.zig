// Material Showcase — grid of spheres with varying roughness and metallic values.
//
// Demonstrates: PBR material system (roughness × metallic grid),
// directional + point lighting, shadow casting.

const engine_mod = @import("engine");
const Engine = engine_mod.Engine;
const ecs = engine_mod.ecs;
const core = engine_mod.core_components;
const example_components = engine_mod.components;

pub const name = "Material Showcase";

const rows = 7;
const cols = 7;

entities: [128]ecs.entity_t = .{0} ** 128,
entity_count: u32 = 0,
materials: [64]u32 = .{0} ** 64,
material_count: u32 = 0,

const Self = @This();

pub fn setup(self: *Self, engine: *Engine, cam: ecs.entity_t) void {
    self.* = .{};

    // Neutral lighting
    engine.clear_color = .{ 0.12, 0.12, 0.15, 1.0 };
    engine.ambient_color = .{ 0.1, 0.1, 0.12, 0.0 };
    engine.fog_enabled = false;

    // Camera
    if (ecs.get_mut(engine.world, cam, core.Position)) |pos| {
        pos.* = .{ .x = 0, .y = 5, .z = 10 };
    }
    if (ecs.get_mut(engine.world, cam, core.Rotation)) |rot| {
        rot.* = .{ .x = 20, .y = 0, .z = 0 };
    }

    // Directional light (strong, slightly warm)
    const light = self.track(engine);
    _ = ecs.set(engine.world, light, core.DirectionalLight, .{
        .dir_x = 0.5, .dir_y = 0.8, .dir_z = 0.3,
        .r = 1.0, .g = 0.97, .b = 0.92,
    });

    // Fill light from below-left (cool)
    const fill = self.track(engine);
    _ = ecs.set(engine.world, fill, core.Position, .{ .x = -8, .y = 2, .z = 8 });
    _ = ecs.set(engine.world, fill, core.PointLight, .{ .radius = 20, .r = 0.6, .g = 0.7, .b = 1.0, .intensity = 3.0 });

    // Warm rim light from right
    const rim = self.track(engine);
    _ = ecs.set(engine.world, rim, core.Position, .{ .x = 10, .y = 4, .z = -2 });
    _ = ecs.set(engine.world, rim, core.PointLight, .{ .radius = 20, .r = 1.0, .g = 0.85, .b = 0.6, .intensity = 2.0 });

    // Floor
    const floor_mat = self.trackMat(engine, engine.createMaterial(.{ .albedo = .{ 0.2, 0.2, 0.22, 1.0 }, .roughness = 0.95 }) catch 0);
    const floor = self.track(engine);
    _ = ecs.set(engine.world, floor, core.Position, .{ .x = 0, .y = -0.6, .z = 0 });
    _ = ecs.set(engine.world, floor, core.MeshHandle, .{ .id = engine.findMesh("cube") orelse 0 });
    _ = ecs.set(engine.world, floor, core.MaterialHandle, .{ .id = floor_mat });
    _ = ecs.set(engine.world, floor, core.Scale, .{ .x = 20, .y = 0.2, .z = 20 });
    _ = ecs.set(engine.world, floor, core.Rotation, .{});
    ecs.add(engine.world, floor, core.ShadowCaster);
    ecs.add(engine.world, floor, core.ShadowReceiver);

    // Grid of spheres: rows = roughness (0.05 to 1.0), columns = metallic (0 to 1)
    const spacing: f32 = 1.4;
    const x_offset: f32 = -@as(f32, @floatFromInt(cols - 1)) * spacing / 2.0;
    const z_offset: f32 = -@as(f32, @floatFromInt(rows - 1)) * spacing / 2.0;

    for (0..rows) |row| {
        const roughness = 0.05 + (@as(f32, @floatFromInt(row)) / @as(f32, @floatFromInt(rows - 1))) * 0.95;
        for (0..cols) |col| {
            const metallic = @as(f32, @floatFromInt(col)) / @as(f32, @floatFromInt(cols - 1));
            const mat = self.trackMat(engine, engine.createMaterial(.{
                .albedo = .{ 0.9, 0.3, 0.2, 1.0 },
                .metallic = metallic,
                .roughness = roughness,
            }) catch 0);
            const e = self.track(engine);
            _ = ecs.set(engine.world, e, core.Position, .{
                .x = x_offset + @as(f32, @floatFromInt(col)) * spacing,
                .y = 0.5,
                .z = z_offset + @as(f32, @floatFromInt(row)) * spacing,
            });
            _ = ecs.set(engine.world, e, core.MeshHandle, .{ .id = engine.findMesh("sphere") orelse 0 });
            _ = ecs.set(engine.world, e, core.MaterialHandle, .{ .id = mat });
            _ = ecs.set(engine.world, e, core.Scale, .{ .x = 0.5, .y = 0.5, .z = 0.5 });
            _ = ecs.set(engine.world, e, core.Rotation, .{});
            ecs.add(engine.world, e, core.ShadowCaster);
            ecs.add(engine.world, e, core.ShadowReceiver);

            // Add Spin so the Lua spin system picks these up.
            // Speed varies by column for a nice staggered effect.
            const spin_speed = 20.0 + @as(f32, @floatFromInt(col)) * 15.0;
            _ = ecs.set(engine.world, e, example_components.Spin, .{ .speed = spin_speed });
        }
    }
}

pub fn update(_: *Self, _: *Engine, _: f32) void {
    // Spheres are animated by the Lua spin system.
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
