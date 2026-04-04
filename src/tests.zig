// tests.zig — Headless integration tests for the Lua API.
// Runs without SDL/GPU — only needs ECS + LuaJIT.

const std = @import("std");
const testing = std.testing;
const engine = @import("main.zig");
const lua = @import("lua.zig");
const lc = lua.c;

/// Set up a fresh engine + Lua state for each test.
fn setup() *lc.lua_State {
    engine.initRegistry();
    engine.resetSystems();
    const L = lc.luaL_newstate() orelse @panic("failed to create Lua state");
    lc.luaL_openlibs(L);
    engine.initLuaApi(L);
    return L;
}

fn teardown(L: *lc.lua_State) void {
    lc.lua_close(L);
    engine.deinitRegistry();
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

/// Run a Lua snippet, expect it to error. Returns the error message.
fn runExpectError(L: *lc.lua_State, code: [*:0]const u8) ![]const u8 {
    if (!lc.luaL_dostring(L, code)) {
        return error.ExpectedError;
    }
    const err = std.mem.span(lc.lua_tolstring(L, -1, null));
    // Don't pop — caller may want to inspect. We'll pop in teardown.
    return err;
}

// ============================================================
// Entity lifecycle
// ============================================================

test "spawn returns incrementing IDs" {
    const L = setup();
    defer teardown(L);
    try run(L,
        \\local a = lunatic.spawn()
        \\local b = lunatic.spawn()
        \\assert(type(a) == "number")
        \\assert(b ~= a)
    );
}

test "destroy then access errors" {
    const L = setup();
    defer teardown(L);
    try run(L,
        \\local e = lunatic.spawn()
        \\lunatic.destroy(e)
        \\local ok, err = pcall(lunatic.add, e, "position", 0, 0, 0)
        \\assert(not ok, "expected error for destroyed entity")
        \\assert(err:find("invalid entity"), err)
    );
}

test "destroy invalid entity errors" {
    const L = setup();
    defer teardown(L);
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
    const L = setup();
    defer teardown(L);
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
    const L = setup();
    defer teardown(L);
    try run(L,
        \\local e = lunatic.spawn()
        \\lunatic.add(e, "player")
        \\assert(lunatic.get(e, "player") == true)
    );
}

test "get missing component returns nothing" {
    const L = setup();
    defer teardown(L);
    try run(L,
        \\local e = lunatic.spawn()
        \\local x = lunatic.get(e, "position")
        \\assert(x == nil, "expected nil for missing component")
    );
}

test "remove component" {
    const L = setup();
    defer teardown(L);
    try run(L,
        \\local e = lunatic.spawn()
        \\lunatic.add(e, "position", 1, 2, 3)
        \\lunatic.remove(e, "position")
        \\local x = lunatic.get(e, "position")
        \\assert(x == nil)
    );
}

test "add unknown component errors" {
    const L = setup();
    defer teardown(L);
    try run(L,
        \\local e = lunatic.spawn()
        \\local ok, err = pcall(lunatic.add, e, "nonexistent", 1, 2, 3)
        \\assert(not ok)
        \\assert(err:find("unknown component"), err)
    );
}

test "add with missing args errors" {
    const L = setup();
    defer teardown(L);
    // Position requires 3 args (x, y, z). With checknumber, missing arg should error.
    try run(L,
        \\local e = lunatic.spawn()
        \\local ok, err = pcall(lunatic.add, e, "position", 1, 2)
        \\assert(not ok, "expected error for missing z argument")
    );
}

test "addOrReplace overwrites existing component" {
    const L = setup();
    defer teardown(L);
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
    const L = setup();
    defer teardown(L);
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
    const L = setup();
    defer teardown(L);
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
    const L = setup();
    defer teardown(L);
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
    const L = setup();
    defer teardown(L);
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
    const L = setup();
    defer teardown(L);
    try run(L,
        \\local e = lunatic.spawn()
        \\local ok, err = pcall(lunatic.ref, e, "position")
        \\assert(not ok)
        \\assert(err:find("has no component"), err)
    );
}

test "ref invalid field errors" {
    const L = setup();
    defer teardown(L);
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
    const L = setup();
    defer teardown(L);
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
    const L = setup();
    defer teardown(L);
    try run(L,
        \\local e = lunatic.spawn()
        \\lunatic.add(e, "position", 0, 0, 0)
        \\lunatic.add(e, "rotation", 0, 0, 0)
        \\
        \\local r1 = lunatic.query("position", "rotation")
        \\local r2 = lunatic.query("rotation", "position")
        \\-- Should return the same cached table (same frame)
        \\assert(r1 == r2, "expected same table for reordered query")
    );
}

test "query empty result" {
    const L = setup();
    defer teardown(L);
    try run(L,
        \\local results = lunatic.query("position")
        \\assert(#results == 0)
    );
}

test "query unknown component errors" {
    const L = setup();
    defer teardown(L);
    try run(L,
        \\local ok, err = pcall(lunatic.query, "nonexistent")
        \\assert(not ok)
        \\assert(err:find("unknown component"), err)
    );
}

// ============================================================
// Systems
// ============================================================

test "system receives dt" {
    const L = setup();
    defer teardown(L);
    try run(L,
        \\received_dt = nil
        \\lunatic.system("test", function(dt)
        \\  received_dt = dt
        \\end)
    );

    // Tick with a known dt
    engine.tickSystems(0.016);

    try run(L,
        \\assert(received_dt ~= nil, "system was not called")
        \\assert(math.abs(received_dt - 0.016) < 0.001, "dt=" .. received_dt)
    );
}

test "failing system is disabled" {
    const L = setup();
    defer teardown(L);
    try run(L,
        \\call_count = 0
        \\lunatic.system("bad", function(dt)
        \\  call_count = call_count + 1
        \\  error("boom")
        \\end)
    );

    // Tick multiple times — system should only fire once
    engine.tickSystems(0.016);
    engine.tickSystems(0.016);
    engine.tickSystems(0.016);

    try run(L,
        \\assert(call_count == 1, "expected 1 call, got " .. call_count)
    );
}

test "multiple systems run in order" {
    const L = setup();
    defer teardown(L);
    try run(L,
        \\order = {}
        \\lunatic.system("first", function(dt) table.insert(order, "a") end)
        \\lunatic.system("second", function(dt) table.insert(order, "b") end)
    );

    engine.tickSystems(0.016);

    try run(L,
        \\assert(#order == 2)
        \\assert(order[1] == "a")
        \\assert(order[2] == "b")
    );
}

// ============================================================
// Settings API (no GPU needed)
// ============================================================

test "set_camera accepts 6 numbers" {
    const L = setup();
    defer teardown(L);
    try run(L,
        \\lunatic.set_camera(0, 5, 10, 0, 0, 0)
    );
}

test "set_clear_color accepts 3 numbers" {
    const L = setup();
    defer teardown(L);
    try run(L,
        \\lunatic.set_clear_color(0.1, 0.2, 0.3)
    );
}

test "set_fog enable and disable" {
    const L = setup();
    defer teardown(L);
    try run(L,
        \\lunatic.set_fog(5, 20, 0.5, 0.5, 0.5)
        \\lunatic.set_fog(false)
    );
}
