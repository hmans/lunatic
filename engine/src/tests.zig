// tests.zig — Headless integration tests for the engine.
// Runs without SDL/GPU — only needs ECS.

const std = @import("std");
const testing = std.testing;
const engine_mod = @import("engine");
const Engine = engine_mod.Engine;
const ecs = engine_mod.ecs;
const core = engine_mod.core_components;

/// Module-level engine instance — pointer-stable across setup/teardown.
var test_engine: Engine = undefined;

fn setup() !void {
    try test_engine.init(.{ .headless = true });
}

fn teardown() void {
    test_engine.deinit();
}

// ============================================================
// Entity lifecycle
// ============================================================

test "spawn returns valid entity IDs" {
    try setup();
    defer teardown();

    const a = ecs.new_id(test_engine.world);
    const b = ecs.new_id(test_engine.world);
    try testing.expect(a != b);
    try testing.expect(a != 0);
    try testing.expect(b != 0);
}

// ============================================================
// Component add/get/remove
// ============================================================

test "add and get position" {
    try setup();
    defer teardown();

    const e = ecs.new_id(test_engine.world);
    _ = ecs.set(test_engine.world, e, core.Position, .{ .x = 1.5, .y = 2.5, .z = 3.5 });

    const pos = ecs.get(test_engine.world, e, core.Position).?;
    try testing.expectApproxEqAbs(pos.x, 1.5, 0.001);
    try testing.expectApproxEqAbs(pos.y, 2.5, 0.001);
    try testing.expectApproxEqAbs(pos.z, 3.5, 0.001);
}

test "add tag component" {
    try setup();
    defer teardown();

    const e = ecs.new_id(test_engine.world);
    ecs.add(test_engine.world, e, core.ShadowCaster);
    try testing.expect(ecs.has_id(test_engine.world, e, ecs.id(core.ShadowCaster)));
}

test "get missing component returns null" {
    try setup();
    defer teardown();

    const e = ecs.new_id(test_engine.world);
    const pos = ecs.get(test_engine.world, e, core.Position);
    try testing.expect(pos == null);
}

test "remove component" {
    try setup();
    defer teardown();

    const e = ecs.new_id(test_engine.world);
    _ = ecs.set(test_engine.world, e, core.Position, .{ .x = 1, .y = 2, .z = 3 });
    ecs.remove(test_engine.world, e, core.Position);
    try testing.expect(ecs.get(test_engine.world, e, core.Position) == null);
}

test "overwrite existing component" {
    try setup();
    defer teardown();

    const e = ecs.new_id(test_engine.world);
    _ = ecs.set(test_engine.world, e, core.Position, .{ .x = 1, .y = 2, .z = 3 });
    _ = ecs.set(test_engine.world, e, core.Position, .{ .x = 4, .y = 5, .z = 6 });

    const pos = ecs.get(test_engine.world, e, core.Position).?;
    try testing.expectApproxEqAbs(pos.x, 4.0, 0.001);
    try testing.expectApproxEqAbs(pos.y, 5.0, 0.001);
    try testing.expectApproxEqAbs(pos.z, 6.0, 0.001);
}

// ============================================================
// Queries
// ============================================================

test "query returns matching entities" {
    try setup();
    defer teardown();

    const a = ecs.new_id(test_engine.world);
    _ = ecs.set(test_engine.world, a, core.Position, .{});
    _ = ecs.set(test_engine.world, a, core.Rotation, .{});

    const b = ecs.new_id(test_engine.world);
    _ = ecs.set(test_engine.world, b, core.Position, .{});
    // b has no rotation

    const q = engine_mod.queryInit(test_engine.world, &.{ ecs.id(core.Position), ecs.id(core.Rotation) }, &.{});
    defer ecs.query_fini(q);

    var it = ecs.query_iter(test_engine.world, q);
    var count: usize = 0;
    while (ecs.query_next(&it)) {
        count += it.count();
    }
    try testing.expectEqual(@as(usize, 1), count);
}

// ============================================================
// Systems
// ============================================================

test "zig system receives dt via tickSystems" {
    try setup();
    defer teardown();

    const S = struct {
        var received_dt: f32 = -1;
        fn run(_: *Engine, dt: f32) void {
            received_dt = dt;
        }
    };

    test_engine.addSystem("test_dt", S.run, ecs.OnUpdate);
    test_engine.tickSystems(0.016);

    try testing.expectApproxEqAbs(S.received_dt, 0.016, 0.001);
}

// ============================================================
// Settings API (no GPU needed)
// ============================================================

test "camera entity can be created" {
    try setup();
    defer teardown();

    const cam = ecs.new_id(test_engine.world);
    _ = ecs.set(test_engine.world, cam, core.Position, .{ .x = 0, .y = 5, .z = 10 });
    _ = ecs.set(test_engine.world, cam, core.Rotation, .{ .x = -30, .y = 0, .z = 0 });
    _ = ecs.set(test_engine.world, cam, core.Camera, .{ .fov = 60, .near = 0.1, .far = 100 });

    const camera = ecs.get(test_engine.world, cam, core.Camera).?;
    try testing.expectApproxEqAbs(camera.fov, 60.0, 0.001);
}
