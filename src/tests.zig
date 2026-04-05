// tests.zig — Headless integration tests for the Lua API.
// Runs without SDL/GPU — only needs ECS + LuaJIT.

const std = @import("std");
const testing = std.testing;
const Engine = @import("engine").Engine;
const lua = @import("lua");
const lc = lua.c;

/// Module-level engine instance — pointer-stable across setup/teardown.
var test_engine: Engine = undefined;

fn setup() !*lc.lua_State {
    try test_engine.init(.{ .headless = true });
    return test_engine.lua_state.?;
}

fn teardown() void {
    test_engine.deinit();
}

/// Run a Lua snippet, fail the test if it errors.
fn run(L: *lc.lua_State, code: [*:0]const u8) !void {
    if (lc.luaL_dostring(L, code)) {
        const err_msg = lc.lua_tolstring(L, -1, null);
        std.debug.print("Lua error: {s}\n", .{err_msg});
        lc.lua_pop(L, 1);
        return error.LuaError;
    }
}

// ============================================================
// Entity lifecycle
// ============================================================

test "spawn returns incrementing IDs" {
    const L = try setup();
    defer teardown();
    try run(L,
        \\local a = lunatic.spawn()
        \\local b = lunatic.spawn()
        \\assert(type(a) == "number")
        \\assert(b ~= a)
    );
}

test "destroy then access errors" {
    const L = try setup();
    defer teardown();
    try run(L,
        \\local e = lunatic.spawn()
        \\lunatic.destroy(e)
        \\local ok, err = pcall(lunatic.add, e, "position", 0, 0, 0)
        \\assert(not ok, "expected error for destroyed entity")
        \\assert(err:find("invalid entity"), err)
    );
}

test "destroy invalid entity errors" {
    const L = try setup();
    defer teardown();
    try run(L,
        \\local ok, err = pcall(lunatic.destroy, 999999)
        \\assert(not ok)
        \\assert(err:find("invalid entity"), err)
    );
}

// ============================================================
// Component add/get/remove
// ============================================================

test "add and get position" {
    const L = try setup();
    defer teardown();
    try run(L,
        \\local e = lunatic.spawn()
        \\lunatic.add(e, "position", 1.5, 2.5, 3.5)
        \\local x, y, z = lunatic.get(e, "position")
        \\assert(math.abs(x - 1.5) < 0.001, "x=" .. x)
        \\assert(math.abs(y - 2.5) < 0.001, "y=" .. y)
        \\assert(math.abs(z - 3.5) < 0.001, "z=" .. z)
    );
}

test "add tag component" {
    const L = try setup();
    defer teardown();
    try run(L,
        \\local e = lunatic.spawn()
        \\lunatic.add(e, "player")
        \\assert(lunatic.get(e, "player") == true)
    );
}

test "get missing component returns nothing" {
    const L = try setup();
    defer teardown();
    try run(L,
        \\local e = lunatic.spawn()
        \\local x = lunatic.get(e, "position")
        \\assert(x == nil, "expected nil for missing component")
    );
}

test "remove component" {
    const L = try setup();
    defer teardown();
    try run(L,
        \\local e = lunatic.spawn()
        \\lunatic.add(e, "position", 1, 2, 3)
        \\lunatic.remove(e, "position")
        \\local x = lunatic.get(e, "position")
        \\assert(x == nil)
    );
}

test "add unknown component errors" {
    const L = try setup();
    defer teardown();
    try run(L,
        \\local e = lunatic.spawn()
        \\local ok, err = pcall(lunatic.add, e, "nonexistent", 1, 2, 3)
        \\assert(not ok)
        \\assert(err:find("unknown component"), err)
    );
}

test "add with missing args uses defaults" {
    const L = try setup();
    defer teardown();
    try run(L,
        \\local e = lunatic.spawn()
        \\lunatic.add(e, "position", 1, 2)
        \\local x, y, z = lunatic.get(e, "position")
        \\assert(math.abs(x - 1) < 0.001)
        \\assert(math.abs(y - 2) < 0.001)
        \\assert(math.abs(z - 0) < 0.001, "missing z should default to 0")
    );
}

test "addOrReplace overwrites existing component" {
    const L = try setup();
    defer teardown();
    try run(L,
        \\local e = lunatic.spawn()
        \\lunatic.add(e, "position", 1, 2, 3)
        \\lunatic.add(e, "position", 4, 5, 6)
        \\local x, y, z = lunatic.get(e, "position")
        \\assert(math.abs(x - 4) < 0.001)
        \\assert(math.abs(y - 5) < 0.001)
        \\assert(math.abs(z - 6) < 0.001)
    );
}

// ============================================================
// Component refs
// ============================================================

test "ref read fields" {
    const L = try setup();
    defer teardown();
    try run(L,
        \\local e = lunatic.spawn()
        \\lunatic.add(e, "position", 10, 20, 30)
        \\local pos = lunatic.ref(e, "position")
        \\assert(math.abs(pos.x - 10) < 0.001)
        \\assert(math.abs(pos.y - 20) < 0.001)
        \\assert(math.abs(pos.z - 30) < 0.001)
    );
}

test "ref write fields" {
    const L = try setup();
    defer teardown();
    try run(L,
        \\local e = lunatic.spawn()
        \\lunatic.add(e, "position", 0, 0, 0)
        \\local pos = lunatic.ref(e, "position")
        \\pos.x = 99
        \\local x, y, z = lunatic.get(e, "position")
        \\assert(math.abs(x - 99) < 0.001, "x=" .. x)
    );
}

test "ref on destroyed entity errors" {
    const L = try setup();
    defer teardown();
    try run(L,
        \\local e = lunatic.spawn()
        \\lunatic.add(e, "position", 1, 2, 3)
        \\local pos = lunatic.ref(e, "position")
        \\lunatic.destroy(e)
        \\local ok, err = pcall(function() return pos.x end)
        \\assert(not ok, "expected error for stale ref")
        \\assert(err:find("stale ref"), err)
    );
}

test "ref write to destroyed entity errors" {
    const L = try setup();
    defer teardown();
    try run(L,
        \\local e = lunatic.spawn()
        \\lunatic.add(e, "position", 1, 2, 3)
        \\local pos = lunatic.ref(e, "position")
        \\lunatic.destroy(e)
        \\local ok, err = pcall(function() pos.x = 5 end)
        \\assert(not ok, "expected error for stale ref write")
        \\assert(err:find("stale ref"), err)
    );
}

test "ref on entity without component errors" {
    const L = try setup();
    defer teardown();
    try run(L,
        \\local e = lunatic.spawn()
        \\local ok, err = pcall(lunatic.ref, e, "position")
        \\assert(not ok)
        \\assert(err:find("has no component"), err)
    );
}

test "ref invalid field errors" {
    const L = try setup();
    defer teardown();
    try run(L,
        \\local e = lunatic.spawn()
        \\lunatic.add(e, "position", 1, 2, 3)
        \\local pos = lunatic.ref(e, "position")
        \\local ok, err = pcall(function() return pos.w end)
        \\assert(not ok)
        \\assert(err:find("no field"), err)
    );
}

// ============================================================
// Queries
// ============================================================

test "query returns matching entities" {
    const L = try setup();
    defer teardown();
    try run(L,
        \\local a = lunatic.spawn()
        \\lunatic.add(a, "position", 0, 0, 0)
        \\lunatic.add(a, "rotation", 0, 0, 0)
        \\
        \\local b = lunatic.spawn()
        \\lunatic.add(b, "position", 1, 1, 1)
        \\-- b has no rotation
        \\
        \\local results = lunatic.query("position", "rotation")
        \\assert(#results == 1, "expected 1 match, got " .. #results)
        \\assert(results[1] == a)
    );
}

test "query order independence" {
    const L = try setup();
    defer teardown();
    try run(L,
        \\local e = lunatic.spawn()
        \\lunatic.add(e, "position", 0, 0, 0)
        \\lunatic.add(e, "rotation", 0, 0, 0)
        \\
        \\local r1 = lunatic.query("position", "rotation")
        \\local r2 = lunatic.query("rotation", "position")
        \\-- Both queries should find the same entity regardless of argument order
        \\assert(#r1 == #r2, "expected same count for reordered query")
        \\assert(r1[1] == r2[1], "expected same entity for reordered query")
    );
}

test "query empty result" {
    const L = try setup();
    defer teardown();
    try run(L,
        \\local results = lunatic.query("position")
        \\assert(#results == 0)
    );
}

test "query unknown component errors" {
    const L = try setup();
    defer teardown();
    try run(L,
        \\local ok, err = pcall(lunatic.query, "nonexistent")
        \\assert(not ok)
        \\assert(err:find("unknown component"), err)
    );
}

// ============================================================
// Each (callback-based iteration)
// ============================================================

test "each iterates matching entities" {
    const L = try setup();
    defer teardown();
    try run(L,
        \\local a = lunatic.spawn()
        \\lunatic.add(a, "position", 1, 2, 3)
        \\lunatic.add(a, "rotation", 0, 0, 0)
        \\
        \\local b = lunatic.spawn()
        \\lunatic.add(b, "position", 4, 5, 6)
        \\-- b has no rotation
        \\
        \\local count = 0
        \\local found_entity = nil
        \\lunatic.each("position", "rotation", function(entity)
        \\  count = count + 1
        \\  found_entity = entity
        \\end)
        \\assert(count == 1, "expected 1 match, got " .. count)
        \\assert(found_entity == a)
    );
}

test "each with single component" {
    const L = try setup();
    defer teardown();
    try run(L,
        \\local a = lunatic.spawn()
        \\lunatic.add(a, "position", 0, 0, 0)
        \\local b = lunatic.spawn()
        \\lunatic.add(b, "position", 1, 1, 1)
        \\
        \\local count = 0
        \\lunatic.each("position", function(entity)
        \\  count = count + 1
        \\end)
        \\assert(count == 2, "expected 2 matches, got " .. count)
    );
}

// ============================================================
// Persistent queries (create_query / each_query)
// ============================================================

test "create_query and each_query iterate matching entities" {
    const L = try setup();
    defer teardown();
    try run(L,
        \\local a = lunatic.spawn()
        \\lunatic.add(a, "position", 1, 2, 3)
        \\lunatic.add(a, "rotation", 0, 0, 0)
        \\
        \\local b = lunatic.spawn()
        \\lunatic.add(b, "position", 4, 5, 6)
        \\-- b has no rotation
        \\
        \\local q = lunatic.create_query("position", "rotation")
        \\local count = 0
        \\lunatic.each_query(q, function(e)
        \\  count = count + 1
        \\end)
        \\assert(count == 1, "expected 1, got " .. count)
    );
}

test "live query updates when components are added" {
    const L = try setup();
    defer teardown();
    try run(L,
        \\local q = lunatic.create_query("position", "rotation")
        \\
        \\local e = lunatic.spawn()
        \\lunatic.add(e, "position", 0, 0, 0)
        \\-- not yet in query (missing rotation)
        \\
        \\local count = 0
        \\lunatic.each_query(q, function(ent) count = count + 1 end)
        \\assert(count == 0, "expected 0 before adding rotation, got " .. count)
        \\
        \\lunatic.add(e, "rotation", 0, 0, 0)
        \\-- now matches
        \\
        \\count = 0
        \\lunatic.each_query(q, function(ent) count = count + 1 end)
        \\assert(count == 1, "expected 1 after adding rotation, got " .. count)
    );
}

test "live query updates when components are removed" {
    const L = try setup();
    defer teardown();
    try run(L,
        \\local e = lunatic.spawn()
        \\lunatic.add(e, "position", 0, 0, 0)
        \\lunatic.add(e, "rotation", 0, 0, 0)
        \\
        \\local q = lunatic.create_query("position", "rotation")
        \\
        \\local count = 0
        \\lunatic.each_query(q, function(ent) count = count + 1 end)
        \\assert(count == 1, "expected 1 before remove, got " .. count)
        \\
        \\lunatic.remove(e, "rotation")
        \\
        \\count = 0
        \\lunatic.each_query(q, function(ent) count = count + 1 end)
        \\assert(count == 0, "expected 0 after remove, got " .. count)
    );
}

test "live query updates when entity is destroyed" {
    const L = try setup();
    defer teardown();
    try run(L,
        \\local e = lunatic.spawn()
        \\lunatic.add(e, "position", 0, 0, 0)
        \\lunatic.add(e, "rotation", 0, 0, 0)
        \\
        \\local q = lunatic.create_query("position", "rotation")
        \\
        \\local count = 0
        \\lunatic.each_query(q, function(ent) count = count + 1 end)
        \\assert(count == 1)
        \\
        \\lunatic.destroy(e)
        \\
        \\count = 0
        \\lunatic.each_query(q, function(ent) count = count + 1 end)
        \\assert(count == 0)
    );
}

// ============================================================
// Systems
// ============================================================

test "system receives dt" {
    const L = try setup();
    defer teardown();
    try run(L,
        \\received_dt = nil
        \\lunatic.system("test", function(dt)
        \\  received_dt = dt
        \\end)
    );

    test_engine.runLuaSystems(0.016);

    try run(L,
        \\assert(received_dt ~= nil, "system was not called")
        \\assert(math.abs(received_dt - 0.016) < 0.001, "dt=" .. received_dt)
    );
}

test "failing system is disabled" {
    const L = try setup();
    defer teardown();
    try run(L,
        \\call_count = 0
        \\lunatic.system("bad", function(dt)
        \\  call_count = call_count + 1
        \\  error("boom")
        \\end)
    );

    test_engine.runLuaSystems(0.016);
    test_engine.runLuaSystems(0.016);
    test_engine.runLuaSystems(0.016);

    try run(L,
        \\assert(call_count == 1, "expected 1 call, got " .. call_count)
    );
}

test "multiple systems run in order" {
    const L = try setup();
    defer teardown();
    try run(L,
        \\order = {}
        \\lunatic.system("first", function(dt) table.insert(order, "a") end)
        \\lunatic.system("second", function(dt) table.insert(order, "b") end)
    );

    test_engine.runLuaSystems(0.016);

    try run(L,
        \\assert(#order == 2)
        \\assert(order[1] == "a")
        \\assert(order[2] == "b")
    );
}

// ============================================================
// Settings API (no GPU needed)
// ============================================================

test "camera entity can be created" {
    const L = try setup();
    defer teardown();
    try run(L,
        \\local cam = lunatic.spawn()
        \\lunatic.add(cam, "position", 0, 5, 10)
        \\lunatic.add(cam, "rotation", -30, 0, 0)
        \\lunatic.add(cam, "camera", 60, 0.1, 100, 0, 0, 1, 1)
    );
}

test "set_clear_color accepts 3 numbers" {
    const L = try setup();
    defer teardown();
    try run(L,
        \\lunatic.set_clear_color(0.1, 0.2, 0.3)
    );
}

test "set_fog enable and disable" {
    const L = try setup();
    defer teardown();
    try run(L,
        \\lunatic.set_fog(5, 20, 0.5, 0.5, 0.5)
        \\lunatic.set_fog(false)
    );
}
