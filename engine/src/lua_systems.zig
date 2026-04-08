// lua_systems.zig — Per-system LuaJIT VM management with auto-discovery.
//
// Each Lua system gets its own lua_State, enabling parallel execution via
// the flecs scheduler. Lua files are self-describing: they declare their
// component access via a `terms` table, and the engine resolves component
// names to ECS IDs using a comptime-generated bridge.
//
// Usage from Zig:
//   engine.loadLuaSystems("game/systems");  // scans directory, auto-registers all .lua files
//
// Lua system format:
//   terms = { { "Position", "inout" }, { "Spin", "in" } }
//   function system(entity, dt, position, spin)
//       position.y = position.y + spin.speed * dt
//   end

const std = @import("std");
const ecs = @import("zflecs");
const lua = @import("lua");
const lc = lua.c;
const engine_mod = @import("engine");
const Engine = engine_mod.Engine;
const all_components = engine_mod.components.all;

// ============================================================
// Public types
// ============================================================

pub const ComponentAccess = enum { in, inout };

/// A single component term for a Lua system.
pub const LuaTerm = struct {
    component_id: ecs.id_t,
    access: ComponentAccess,
    /// Push component data from ECS onto the Lua stack as a table.
    push_fn: *const fn (world: *ecs.world_t, entity: ecs.entity_t, L: *lc.lua_State) void,
    /// Read modified component data from a Lua table back into ECS.
    /// Only used for .inout terms.
    write_back_fn: ?*const fn (world: *ecs.world_t, entity: ecs.entity_t, L: *lc.lua_State, stack_idx: c_int) void,
};

/// Descriptor for registering a Lua system (manual API, still supported).
pub const LuaSystemDesc = struct {
    name: [*:0]const u8,
    script: [*:0]const u8,
    phase: ecs.entity_t = 0,
    terms: []const LuaTerm,
};

// ============================================================
// Comptime component bridge
// ============================================================

/// A bridge entry maps a component name string to its push/writeback functions.
/// Generated at comptime for every component in the `all` tuple.
const BridgeEntry = struct {
    name: []const u8,
    id_fn: *const fn () ecs.id_t,
    push_fn: *const fn (world: *ecs.world_t, entity: ecs.entity_t, L: *lc.lua_State) void,
    write_back_fn: *const fn (world: *ecs.world_t, entity: ecs.entity_t, L: *lc.lua_State, stack_idx: c_int) void,
};

/// Comptime-generated bridge table for all registered component types.
/// Maps component names (e.g. "Position", "Spin") to push/writeback functions.
const bridge_table: [all_components.len]BridgeEntry = blk: {
    var entries: [all_components.len]BridgeEntry = undefined;
    for (all_components, 0..) |T, i| {
        entries[i] = .{
            .name = shortTypeName(T),
            .id_fn = &struct {
                fn f() ecs.id_t {
                    return ecs.id(T);
                }
            }.f,
            .push_fn = &makePushFn(T).f,
            .write_back_fn = &makeWriteBackFn(T).f,
        };
    }
    break :blk entries;
};

/// Look up a component bridge by name. Returns null if not found.
fn findBridge(name: []const u8) ?BridgeEntry {
    for (bridge_table) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

/// Extract the short type name from `@typeName(T)`.
/// e.g. "core_components.Position" → "Position", "components.Spin" → "Spin"
fn shortTypeName(comptime T: type) []const u8 {
    const full = @typeName(T);
    // Find last '.' and return everything after it
    var i: usize = full.len;
    while (i > 0) {
        i -= 1;
        if (full[i] == '.') return full[i + 1 ..];
    }
    return full;
}

/// Create a LuaTerm for a component type (manual API, still supported).
pub fn term(comptime T: type, access: ComponentAccess) LuaTerm {
    return .{
        .component_id = ecs.id(T),
        .access = access,
        .push_fn = &makePushFn(T).f,
        .write_back_fn = if (access == .inout) &makeWriteBackFn(T).f else null,
    };
}

/// Generate a function that pushes component T's fields onto a Lua table.
fn makePushFn(comptime T: type) type {
    return struct {
        fn f(world: *ecs.world_t, entity: ecs.entity_t, L: *lc.lua_State) void {
            if (@sizeOf(T) == 0) return; // tag component, nothing to push
            const val = ecs.get(world, entity, T) orelse return;
            inline for (@typeInfo(T).@"struct".fields) |field| {
                const fval = @field(val.*, field.name);
                if (comptime field.type == f32) {
                    lc.lua_pushnumber(L, fval);
                } else if (comptime field.type == u32) {
                    lc.lua_pushinteger(L, @intCast(fval));
                } else {
                    continue;
                }
                lc.lua_setfield(L, -2, @as([*:0]const u8, @ptrCast(field.name.ptr)));
            }
        }
    };
}

/// Generate a function that reads component T's fields from a Lua table
/// and writes them back to the ECS.
fn makeWriteBackFn(comptime T: type) type {
    return struct {
        fn f(world: *ecs.world_t, entity: ecs.entity_t, L: *lc.lua_State, stack_idx: c_int) void {
            if (@sizeOf(T) == 0) return; // tag component, nothing to write back
            var val: T = (ecs.get(world, entity, T) orelse return).*;
            inline for (@typeInfo(T).@"struct".fields) |field| {
                lc.lua_getfield(L, stack_idx, @as([*:0]const u8, @ptrCast(field.name.ptr)));
                if (comptime field.type == f32) {
                    @field(val, field.name) = @floatCast(lc.lua_tonumber(L, -1));
                } else if (comptime field.type == u32) {
                    @field(val, field.name) = @intCast(lc.lua_tointeger(L, -1));
                }
                lc.lua_settop(L, -2); // pop value
                continue;
            }
            _ = ecs.set(world, entity, T, val);
        }
    };
}

// ============================================================
// Per-system state
// ============================================================

const max_lua_systems = 32;
const max_terms = 8;

const LuaSystemState = struct {
    lua_state: ?*lc.lua_State = null,
    func_ref: c_int = 0,
    scratch_refs: [max_terms]c_int = .{0} ** max_terms,
    terms: [max_terms]LuaTerm = undefined,
    term_count: u8 = 0,
    enabled: bool = false,
    elapsed: f64 = 0,

    script_path: [256]u8 = .{0} ** 256,
    script_len: usize = 0,
    last_mtime: i128 = 0,

    // System name for logging (derived from filename)
    name_buf: [64]u8 = .{0} ** 64,
    name_len: usize = 0,

    fn deinit(self: *LuaSystemState) void {
        if (self.lua_state) |L| lc.lua_close(L);
        self.lua_state = null;
        self.enabled = false;
    }

    fn name(self: *const LuaSystemState) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

// ============================================================
// Lua system manager
// ============================================================

pub const LuaSystemManager = struct {
    systems: [max_lua_systems]LuaSystemState = .{LuaSystemState{}} ** max_lua_systems,
    system_count: u32 = 0,

    /// Scan a directory for .lua files and auto-register each as a Lua system.
    /// Each .lua file must declare a `terms` table and a `system()` function.
    /// Component names in `terms` are resolved via the comptime bridge table.
    pub fn scanDirectory(self: *LuaSystemManager, engine: *Engine, dir_path: []const u8) void {
        const cwd = std.fs.cwd();
        var dir = cwd.openDir(dir_path, .{ .iterate = true }) catch |err| {
            std.debug.print("[lua-systems] failed to open directory '{s}': {}\n", .{ dir_path, err });
            return;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".lua")) continue;

            // Build full path: dir_path + "/" + filename
            var path_buf: [256]u8 = undefined;
            const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;

            self.autoRegister(engine, full_path, entry.name);
        }
    }

    /// Register a Lua system with explicit terms (manual API).
    pub fn register(self: *LuaSystemManager, engine: *Engine, desc: LuaSystemDesc) void {
        if (self.system_count >= max_lua_systems) {
            std.debug.print("[lua-systems] max systems reached ({d})\n", .{max_lua_systems});
            return;
        }

        const idx = self.system_count;
        var sys = &self.systems[idx];
        sys.* = LuaSystemState{};

        // Store terms
        const term_count: u8 = @intCast(@min(desc.terms.len, max_terms));
        for (desc.terms[0..term_count], 0..) |t, i| {
            sys.terms[i] = t;
        }
        sys.term_count = term_count;

        // Store script path
        const path = std.mem.span(desc.script);
        @memcpy(sys.script_path[0..path.len], path);
        sys.script_len = path.len;

        // Store name
        const name_span = std.mem.span(desc.name);
        @memcpy(sys.name_buf[0..name_span.len], name_span);
        sys.name_len = name_span.len;

        // Create Lua VM and load script
        if (!initVm(sys)) {
            std.debug.print("[lua-systems] failed to init VM for '{s}'\n", .{desc.name});
            return;
        }

        sys.last_mtime = getFileMtime(sys.script_path[0..sys.script_len]);
        self.registerFlecsSystem(engine, sys, idx);
    }

    /// Check all Lua systems for file changes and reload as needed.
    pub fn checkHotReload(self: *LuaSystemManager) void {
        for (self.systems[0..self.system_count]) |*sys| {
            if (sys.lua_state == null) continue;
            const path = sys.script_path[0..sys.script_len];
            const mtime = getFileMtime(path);
            if (mtime != sys.last_mtime and mtime != 0) {
                sys.last_mtime = mtime;
                reloadScript(sys);
            }
        }
    }

    /// Clean up all Lua VMs.
    pub fn deinit(self: *LuaSystemManager) void {
        for (self.systems[0..self.system_count]) |*sys| {
            sys.deinit();
        }
        self.system_count = 0;
    }

    // ---- Internal ----

    /// Auto-register a single .lua file by reading its `terms` table.
    fn autoRegister(self: *LuaSystemManager, engine: *Engine, path: []const u8, filename: []const u8) void {
        if (self.system_count >= max_lua_systems) {
            std.debug.print("[lua-systems] max systems reached, skipping {s}\n", .{filename});
            return;
        }

        const idx = self.system_count;
        var sys = &self.systems[idx];
        sys.* = LuaSystemState{};

        // Derive system name from filename (strip .lua extension)
        const name_end = if (std.mem.endsWith(u8, filename, ".lua")) filename.len - 4 else filename.len;
        const sys_name = filename[0..name_end];
        @memcpy(sys.name_buf[0..sys_name.len], sys_name);
        sys.name_len = sys_name.len;

        // Store path
        @memcpy(sys.script_path[0..path.len], path);
        sys.script_len = path.len;

        // Create VM and load script
        const L = lc.luaL_newstate() orelse {
            std.debug.print("[lua-systems] failed to create VM for {s}\n", .{sys_name});
            return;
        };
        lc.luaL_openlibs(L);
        sys.lua_state = L;

        if (!loadScript(sys)) {
            std.debug.print("[lua-systems] failed to load {s}\n", .{path});
            sys.deinit();
            return;
        }

        // Read the `terms` table from the Lua global scope
        lc.lua_getglobal(L, "terms");
        if (lc.lua_type(L, -1) != lc.LUA_TTABLE) {
            std.debug.print("[lua-systems] {s}: missing `terms` table\n", .{sys_name});
            lc.lua_settop(L, -2);
            sys.deinit();
            return;
        }

        // Parse terms: { { "ComponentName", "in"|"inout" }, ... }
        const n = lc.lua_objlen(L, -1);
        if (n == 0 or n > max_terms) {
            std.debug.print("[lua-systems] {s}: terms table has {d} entries (expected 1-{d})\n", .{ sys_name, n, max_terms });
            lc.lua_settop(L, -2);
            sys.deinit();
            return;
        }

        var term_count: u8 = 0;
        var ok = true;
        for (1..n + 1) |i| {
            lc.lua_rawgeti(L, -1, @intCast(i)); // push terms[i]

            // Read component name (first element)
            lc.lua_rawgeti(L, -1, 1);
            const comp_name_ptr = lc.lua_tolstring(L, -1, null);
            lc.lua_settop(L, -2); // pop name

            // Read access mode (second element)
            lc.lua_rawgeti(L, -1, 2);
            const access_ptr = lc.lua_tolstring(L, -1, null);
            lc.lua_settop(L, -2); // pop access

            lc.lua_settop(L, -2); // pop terms[i]

            if (comp_name_ptr == null) {
                std.debug.print("[lua-systems] {s}: term {d} has no component name\n", .{ sys_name, i });
                ok = false;
                break;
            }

            const comp_name = std.mem.span(comp_name_ptr);
            const access: ComponentAccess = if (access_ptr != null and std.mem.eql(u8, std.mem.span(access_ptr), "inout")) .inout else .in;

            const bridge = findBridge(comp_name) orelse {
                std.debug.print("[lua-systems] {s}: unknown component '{s}'\n", .{ sys_name, comp_name });
                ok = false;
                break;
            };

            sys.terms[term_count] = .{
                .component_id = bridge.id_fn(),
                .access = access,
                .push_fn = bridge.push_fn,
                .write_back_fn = if (access == .inout) bridge.write_back_fn else null,
            };
            term_count += 1;
        }
        lc.lua_settop(L, -2); // pop terms table

        if (!ok) {
            sys.deinit();
            return;
        }
        sys.term_count = term_count;

        // Create persistent scratch tables for each term
        for (0..term_count) |i| {
            lc.lua_newtable(L);
            sys.scratch_refs[i] = lc.luaL_ref(L, lc.LUA_REGISTRYINDEX);
        }

        sys.last_mtime = getFileMtime(path);
        self.registerFlecsSystem(engine, sys, idx);
    }

    fn registerFlecsSystem(self: *LuaSystemManager, engine: *Engine, sys: *LuaSystemState, idx: u32) void {
        var flecs_desc = std.mem.zeroes(ecs.system_desc_t);
        flecs_desc.callback = &luaSystemCallback;
        flecs_desc.ctx = engine;
        flecs_desc.callback_ctx = @ptrFromInt(@as(usize, idx));
        flecs_desc.phase = ecs.OnUpdate;
        flecs_desc.multi_threaded = true;

        for (0..sys.term_count) |i| {
            flecs_desc.query.terms[i].id = sys.terms[i].component_id;
            flecs_desc.query.terms[i].inout = switch (sys.terms[i].access) {
                .in => .In,
                .inout => .InOut,
            };
        }

        // Null-terminate the name for flecs
        var name_z: [65]u8 = undefined;
        @memcpy(name_z[0..sys.name_len], sys.name_buf[0..sys.name_len]);
        name_z[sys.name_len] = 0;
        const name_ptr: [*:0]const u8 = @ptrCast(name_z[0..sys.name_len]);

        _ = ecs.SYSTEM(engine.world, name_ptr, &flecs_desc);
        self.system_count += 1;
        sys.enabled = true;

        std.debug.print("[lua-systems] loaded '{s}' from {s} ({d} terms)\n", .{
            sys.name(),
            sys.script_path[0..sys.script_len],
            sys.term_count,
        });
    }

    fn initVm(sys: *LuaSystemState) bool {
        const L = lc.luaL_newstate() orelse return false;
        lc.luaL_openlibs(L);
        sys.lua_state = L;

        // Create persistent scratch tables for each term
        for (0..sys.term_count) |i| {
            lc.lua_newtable(L);
            sys.scratch_refs[i] = lc.luaL_ref(L, lc.LUA_REGISTRYINDEX);
        }

        return loadScript(sys);
    }

    fn loadScript(sys: *LuaSystemState) bool {
        const L = sys.lua_state orelse return false;
        const path = sys.script_path[0..sys.script_len];

        var path_buf: [257]u8 = undefined;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const path_z: [*:0]const u8 = @ptrCast(path_buf[0..path.len]);

        if (lc.luaL_loadfile(L, path_z) != 0 or lc.lua_pcall(L, 0, 0, 0) != 0) {
            const err = lc.lua_tolstring(L, -1, null);
            std.debug.print("[lua-systems] load error: {s}\n", .{err});
            lc.lua_settop(L, -2);
            return false;
        }

        // Cache reference to the global system() function
        lc.lua_getglobal(L, "system");
        if (lc.lua_type(L, -1) != lc.LUA_TFUNCTION) {
            std.debug.print("[lua-systems] script has no system() function: {s}\n", .{path});
            lc.lua_settop(L, -2);
            return false;
        }
        if (sys.func_ref != 0) {
            lc.luaL_unref(L, lc.LUA_REGISTRYINDEX, sys.func_ref);
        }
        sys.func_ref = lc.luaL_ref(L, lc.LUA_REGISTRYINDEX);
        return true;
    }

    fn reloadScript(sys: *LuaSystemState) void {
        const path = sys.script_path[0..sys.script_len];
        if (loadScript(sys)) {
            sys.enabled = true;
            std.debug.print("[lua-systems] reloaded {s}\n", .{path});
        } else {
            sys.enabled = false;
            std.debug.print("[lua-systems] reload failed {s}\n", .{path});
        }
    }
};

// ============================================================
// Flecs callback
// ============================================================

fn luaSystemCallback(it: *ecs.iter_t) callconv(.c) void {
    const engine: *Engine = @ptrCast(@alignCast(it.ctx));
    const sys_idx: usize = @intFromPtr(it.callback_ctx);
    var sys = &engine.lua_sys.systems[sys_idx];

    if (!sys.enabled) return;
    const L = sys.lua_state orelse return;

    sys.elapsed += it.delta_time;
    lc.lua_pushnumber(L, @floatCast(sys.elapsed));
    lc.lua_setglobal(L, "elapsed");

    const world = it.world;

    for (it.entities()) |entity| {
        lc.lua_rawgeti(L, lc.LUA_REGISTRYINDEX, sys.func_ref);
        lc.lua_pushinteger(L, @intCast(entity));
        lc.lua_pushnumber(L, it.delta_time);

        for (0..sys.term_count) |i| {
            lc.lua_rawgeti(L, lc.LUA_REGISTRYINDEX, sys.scratch_refs[i]);
            sys.terms[i].push_fn(world, entity, L);
        }

        const nargs: c_int = @as(c_int, 2) + @as(c_int, @intCast(sys.term_count));
        if (lc.lua_pcall(L, nargs, 0, 0) != 0) {
            const err = lc.lua_tolstring(L, -1, null);
            std.debug.print("[lua-systems] error in '{s}': {s}\n", .{ sys.name(), err });
            lc.lua_settop(L, -2);
            sys.enabled = false;
            return;
        }

        for (0..sys.term_count) |i| {
            if (sys.terms[i].access == .inout) {
                if (sys.terms[i].write_back_fn) |wb| {
                    lc.lua_rawgeti(L, lc.LUA_REGISTRYINDEX, sys.scratch_refs[i]);
                    wb(world, entity, L, lc.lua_gettop(L));
                    lc.lua_settop(L, -2);
                }
            }
        }
    }
}

// ============================================================
// File utilities
// ============================================================

fn getFileMtime(path: []const u8) i128 {
    const cwd = std.fs.cwd();
    const stat = cwd.statFile(path) catch return 0;
    return stat.mtime;
}
