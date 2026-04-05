// Lunatic game — spinning shapes with bloom, fly camera, and debug UI.

const std = @import("std");
const engine_mod = @import("engine");
const Engine = engine_mod.Engine;
const core = engine_mod.core_components;
const c = engine_mod.c;

const Spin = struct { speed: f32 = 0 };

// ---- Systems ----

fn flyCameraSystem(engine: *Engine, dt: f32) void {
    const io = c.igGetIO();
    if (io != null and io.*.WantCaptureMouse) return;

    var cam_view = engine.registry.view(.{ core.Position, core.Rotation, core.Camera }, .{});
    var cam_iter = cam_view.entityIterator();
    const cam_entity = cam_iter.next() orelse return;

    var pos = cam_view.get(core.Position, cam_entity);
    var rot = cam_view.get(core.Rotation, cam_entity);

    const move_speed: f32 = if (isKeyDown(c.SDL_SCANCODE_LSHIFT)) 30 else 10;
    const mouse_sensitivity: f32 = 0.15;

    // Mouse look
    var dx: f32 = 0;
    var dy: f32 = 0;
    _ = c.SDL_GetRelativeMouseState(&dx, &dy);
    rot.y += dx * mouse_sensitivity;
    rot.x += dy * mouse_sensitivity;
    rot.x = std.math.clamp(rot.x, -89, 89);

    // Camera axes from rotation (pitch, yaw)
    const deg2rad = std.math.pi / 180.0;
    const pitch = rot.x * deg2rad;
    const yaw = rot.y * deg2rad;
    const cp = @cos(pitch);
    const sp = @sin(pitch);
    const cy = @cos(yaw);
    const sy = @sin(yaw);

    // Forward (into screen = -Z)
    const fx = sy * cp;
    const fy = -sp;
    const fz = -cy * cp;
    // Right
    const rx = cy;
    const ry: f32 = 0;
    const rz = sy;

    // WASD + Space/Ctrl
    if (isKeyDown(c.SDL_SCANCODE_W)) {
        pos.x += fx * move_speed * dt;
        pos.y += fy * move_speed * dt;
        pos.z += fz * move_speed * dt;
    }
    if (isKeyDown(c.SDL_SCANCODE_S)) {
        pos.x -= fx * move_speed * dt;
        pos.y -= fy * move_speed * dt;
        pos.z -= fz * move_speed * dt;
    }
    if (isKeyDown(c.SDL_SCANCODE_A)) {
        pos.x -= rx * move_speed * dt;
        pos.y -= ry * move_speed * dt;
        pos.z -= rz * move_speed * dt;
    }
    if (isKeyDown(c.SDL_SCANCODE_D)) {
        pos.x += rx * move_speed * dt;
        pos.y += ry * move_speed * dt;
        pos.z += rz * move_speed * dt;
    }
    if (isKeyDown(c.SDL_SCANCODE_SPACE)) pos.y += move_speed * dt;
    if (isKeyDown(c.SDL_SCANCODE_LCTRL)) pos.y -= move_speed * dt;
}

fn debugUiSystem(engine: *Engine, dt: f32) void {
    _ = dt;
    _ = c.igBegin("Debug", null, 0);

    var cam_view = engine.registry.view(.{core.Camera}, .{});
    var cam_iter = cam_view.entityIterator();
    if (cam_iter.next()) |cam_entity| {
        var cam = engine.registry.get(core.Camera, cam_entity);

        c.igSeparatorText("Post-Processing");
        _ = c.igSliderFloat("Exposure", &cam.exposure, 0.1, 5.0);
        _ = c.igSliderFloat("Bloom Intensity", &cam.bloom_intensity, 0.0, 1.0);
    }

    c.igEnd();
}

fn spinSystem(engine: *Engine, dt: f32) void {
    var view = engine.registry.view(.{ core.Rotation, Spin }, .{});
    var iter = view.entityIterator();
    while (iter.next()) |entity| {
        const spin = view.getConst(Spin, entity);
        var rot = view.get(core.Rotation, entity);
        rot.y += spin.speed * dt;
    }
}

fn isKeyDown(scancode: c_uint) bool {
    const state = c.SDL_GetKeyboardState(null);
    return state[scancode];
}

// ---- Setup ----

pub fn main() !void {
    var engine: Engine = undefined;
    try engine.init(.{});
    defer engine.deinit();

    // Scene
    engine.clear_color = .{ 0.08, 0.08, 0.12, 1.0 };
    engine.ambient_color = .{ 0.15, 0.15, 0.25, 0.0 };
    engine.fog_enabled = true;
    engine.fog_start = 15;
    engine.fog_end = 60;
    engine.fog_color = .{ 0.08, 0.08, 0.12 };

    // Light
    const light = engine.registry.create();
    engine.registry.add(light, core.DirectionalLight{
        .dir_x = 0.3, .dir_y = 0.8, .dir_z = 0.5,
    });

    // Materials
    const red = try engine.createMaterial(.{ .albedo = .{ 0.9, 0.2, 0.2, 1 } });
    const green = try engine.createMaterial(.{ .albedo = .{ 0.2, 0.8, 0.3, 1 } });
    const blue = try engine.createMaterial(.{ .albedo = .{ 0.2, 0.3, 0.9, 1 } });
    const yellow = try engine.createMaterial(.{ .albedo = .{ 0.9, 0.8, 0.2, 1 } });
    const emissive_hot = try engine.createMaterial(.{ .albedo = .{ 1, 1, 1, 1 }, .emissive = .{ 3, 1.5, 0.3 } });
    const emissive_cool = try engine.createMaterial(.{ .albedo = .{ 1, 1, 1, 1 }, .emissive = .{ 0.3, 0.8, 3 } });
    const materials = [_]u32{ 0, red, green, blue, yellow, emissive_hot, emissive_cool };

    const meshes = [_]u32{ 0, 1 }; // cube, sphere

    // Camera (fly camera with bloom)
    const cam = engine.registry.create();
    engine.registry.add(cam, core.Position{ .x = 0, .y = 8, .z = 12 });
    engine.registry.add(cam, core.Rotation{ .x = 34, .y = 0, .z = 0 });
    engine.registry.add(cam, core.Camera{
        .fov = 60,
        .near = 0.1,
        .far = 100,
        .exposure = 1.2,
        .bloom_intensity = 0.15,
    });

    // Grab mouse for FPS-style look
    engine.setMouseGrab(true);

    // Grid of shapes
    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();
    var x: i32 = -4;
    while (x <= 4) : (x += 1) {
        var z: i32 = -4;
        while (z <= 4) : (z += 1) {
            const e = engine.registry.create();
            engine.registry.add(e, core.Position{
                .x = @as(f32, @floatFromInt(x)) * 2,
                .y = 0,
                .z = @as(f32, @floatFromInt(z)) * 2,
            });
            engine.registry.add(e, core.Rotation{
                .y = rand.float(f32) * 360,
            });
            engine.registry.add(e, Spin{
                .speed = 30 + rand.float(f32) * 60,
            });
            engine.registry.add(e, core.MeshHandle{
                .id = meshes[rand.intRangeAtMost(usize, 0, meshes.len - 1)],
            });
            engine.registry.add(e, core.MaterialHandle{
                .id = materials[rand.intRangeAtMost(usize, 0, materials.len - 1)],
            });
        }
    }

    // Register systems and run
    engine.addSystem(&flyCameraSystem);
    engine.addSystem(&debugUiSystem);
    engine.addSystem(&spinSystem);
    try engine.run();
}
