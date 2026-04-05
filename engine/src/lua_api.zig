// lua_api.zig — Lua C callbacks and API registration.
//
// All component dispatch goes through the ComponentOps vtable generated from
// components.all. No inline-for loops over the component tuple remain here.

const std = @import("std");
const builtin = @import("builtin");
const components = @import("components");
const ecs = @import("zig-ecs");
const engine_mod = @import("engine");
const Engine = engine_mod.Engine;
const c = engine_mod.c;
const gltf_mod = engine_mod.gltf;

const lua = @import("lua");
const lc = lua.c;
const component_ops = @import("component_ops");
const ComponentOps = component_ops.ComponentOps;

// ============================================================
// Component vtable — generated once at comptime
// ============================================================

const ops_table = component_ops.makeComponentOps(components.all);

const OpsResult = struct { ops: ComponentOps, index: u8 };

fn findOps(name: []const u8) ?OpsResult {
    for (ops_table, 0..) |ops, i| {
        if (std.mem.eql(u8, name, ops.name)) return .{ .ops = ops, .index = @intCast(i) };
    }
    return null;
}

// ============================================================
// Component ref userdata
// ============================================================

const ComponentRef = extern struct {
    entity_id: u32,
    ops_index: u8,
};

const ref_metatable_name: [*:0]const u8 = "lunatic_component_ref";

// ============================================================
// Lua API registration
// ============================================================

pub fn registerLuaApi(self: *Engine) void {
    const L = self.lua_state.?;
    const self_ptr: *anyopaque = @ptrCast(self);

    lc.lua_newtable(L);

    const fns = .{
        .{ "key_down", &luaKeyDown },
        .{ "mouse_delta", &luaMouseDelta },
        .{ "set_mouse_grab", &luaSetMouseGrab },
        .{ "camera_axes", &luaCameraAxes },
        .{ "set_clear_color", &luaSetClearColor },
        .{ "set_fog", &luaSetFog },
        .{ "set_ambient", &luaSetAmbient },
        .{ "set_bloom", &luaSetBloom },
        .{ "get_bloom_tints", &luaGetBloomTints },
        .{ "set_bloom_tints", &luaSetBloomTints },
        .{ "get_bloom_radius", &luaGetBloomRadius },
        .{ "set_bloom_radius", &luaSetBloomRadius },
        .{ "spawn", &luaSpawn },
        .{ "destroy", &luaDestroy },
        .{ "add", &luaAdd },
        .{ "get", &luaGet },
        .{ "remove", &luaRemove },
        .{ "query", &luaQuery },
        .{ "each", &luaEach },
        .{ "create_query", &luaCreateQuery },
        .{ "each_query", &luaEachQuery },
        .{ "ref", &luaRef },
        .{ "create_material", &luaCreateMaterial },
        .{ "create_cube_mesh", &luaCreateCubeMesh },
        .{ "create_sphere_mesh", &luaCreateSphereMesh },
        .{ "load_gltf", &luaLoadGltf },
        .{ "system", &luaSystemRegister },
        .{ "get_stats", &luaGetStats },
        .{ "physics_add_box", &luaPhysicsAddBox },
        .{ "physics_add_sphere", &luaPhysicsAddSphere },
        .{ "physics_add_floor", &luaPhysicsAddFloor },
        .{ "physics_optimize", &luaPhysicsOptimize },
    };

    inline for (fns) |entry| {
        lc.lua_pushlightuserdata(L, self_ptr);
        lc.lua_pushcclosure(L, entry[1], 1);
        lc.lua_setfield(L, -2, entry[0]);
    }

    lc.lua_setglobal(L, "lunatic");

    // ImGui UI bindings (no engine upvalue needed)
    lc.lua_newtable(L);
    const ui_fns = .{
        .{ "begin_window", &luaUiBegin },
        .{ "end_window", &luaUiEnd },
        .{ "text", &luaUiText },
        .{ "separator_text", &luaUiSeparatorText },
        .{ "slider_float", &luaUiSliderFloat },
        .{ "checkbox", &luaUiCheckbox },
        .{ "button", &luaUiButton },
        .{ "collapsing_header", &luaUiCollapsingHeader },
        .{ "set_next_window_pos", &luaUiSetNextWindowPos },
        .{ "set_next_window_size", &luaUiSetNextWindowSize },
        .{ "fps", &luaUiFps },
    };
    inline for (ui_fns) |entry| {
        lc.lua_pushcclosure(L, entry[1], 0);
        lc.lua_setfield(L, -2, entry[0]);
    }
    lc.lua_setglobal(L, "ui");

    _ = lc.luaL_newmetatable(L, ref_metatable_name);

    lc.lua_pushlightuserdata(L, self_ptr);
    lc.lua_pushcclosure(L, &refIndex, 1);
    lc.lua_setfield(L, -2, "__index");

    lc.lua_pushlightuserdata(L, self_ptr);
    lc.lua_pushcclosure(L, &refNewIndex, 1);
    lc.lua_setfield(L, -2, "__newindex");

    lc.lua_pop(L, 1);
}

pub fn publishHandlesToLua(self: *Engine) void {
    const L = self.lua_state orelse return;

    lc.lua_getglobal(L, "lunatic");

    lc.lua_newtable(L);
    for (0..self.assets.mesh_count) |i| {
        if (self.assets.mesh_names[i]) |name| {
            lc.lua_pushinteger(L, @intCast(i));
            lc.lua_setfield(L, -2, name);
        }
    }
    lc.lua_setfield(L, -2, "mesh");

    lc.lua_newtable(L);
    for (0..self.assets.material_count) |i| {
        if (self.assets.material_names[i]) |name| {
            lc.lua_pushinteger(L, @intCast(i));
            lc.lua_setfield(L, -2, name);
        }
    }
    lc.lua_setfield(L, -2, "material");

    lc.lua_pop(L, 1);
}

// ============================================================
// Lua C callbacks — helpers
// ============================================================

fn getEngine(L: ?*lc.lua_State) *Engine {
    const ptr = lc.lua_touserdata(L, lc.LUA_GLOBALSINDEX - 1) orelse {
        @panic("getEngine: missing engine upvalue");
    };
    return @ptrCast(@alignCast(ptr));
}

const EntityResult = struct { entity: ecs.Entity, valid: bool };

fn entityFromLua(self: *Engine, L: ?*lc.lua_State, idx: c_int) EntityResult {
    const id: u32 = @intCast(lc.luaL_checkinteger(L, idx));
    const entity: ecs.Entity = @bitCast(id);
    if (!self.registry.valid(entity)) {
        _ = lc.lua_pushfstring(L, "invalid entity %d", @as(c_int, @intCast(id)));
        return .{ .entity = entity, .valid = false };
    }
    return .{ .entity = entity, .valid = true };
}

/// Helper: get entity or return Lua error. Use at the start of Lua callbacks.
/// Returns null if entity is invalid (error already pushed, caller should return lc.lua_error(L)).
fn getEntityOrError(self: *Engine, L: ?*lc.lua_State, idx: c_int) ?ecs.Entity {
    const result = entityFromLua(self, L, idx);
    if (!result.valid) return null;
    return result.entity;
}

fn componentName(L: ?*lc.lua_State, idx: c_int) []const u8 {
    return std.mem.span(lc.luaL_checklstring(L, idx, null));
}

// ============================================================
// Lua ↔ Zig vector/number helpers
// ============================================================

fn pushVec3(L: ?*lc.lua_State, v: [3]f32) void {
    lc.lua_pushnumber(L, v[0]);
    lc.lua_pushnumber(L, v[1]);
    lc.lua_pushnumber(L, v[2]);
}

fn checkVec3(L: ?*lc.lua_State, base: c_int) [3]f32 {
    return .{
        @floatCast(lc.luaL_checknumber(L, base)),
        @floatCast(lc.luaL_checknumber(L, base + 1)),
        @floatCast(lc.luaL_checknumber(L, base + 2)),
    };
}

fn optVec3(L: ?*lc.lua_State, base: c_int, defaults: [3]f32) [3]f32 {
    return .{
        @floatCast(lc.luaL_optnumber(L, base, defaults[0])),
        @floatCast(lc.luaL_optnumber(L, base + 1, defaults[1])),
        @floatCast(lc.luaL_optnumber(L, base + 2, defaults[2])),
    };
}

fn checkFloat(L: ?*lc.lua_State, idx: c_int) f32 {
    return @floatCast(lc.luaL_checknumber(L, idx));
}

// ============================================================
// ECS callbacks — vtable-dispatched
// ============================================================

fn luaSpawn(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const entity = self.registry.create();
    const entity_int: u32 = @bitCast(entity);
    lc.lua_pushinteger(L, @intCast(entity_int));
    return 1;
}

fn luaDestroy(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const entity = getEntityOrError(self, L, 1) orelse return lc.lua_error(L);
    // Clean up physics body if present
    if (self.registry.tryGet(core_comp.RigidBody, entity)) |rb| {
        const body_id: phys.BodyId = @enumFromInt(rb.body_id);
        if (body_id != .invalid) {
            phys.getBodyInterface(self).removeAndDestroyBody(body_id);
        }
    }
    removeFromAllLiveQueries(self, @bitCast(entity));
    self.registry.destroy(entity);
    return 0;
}

fn luaAdd(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const entity = getEntityOrError(self, L, 1) orelse return lc.lua_error(L);
    const name = componentName(L, 2);
    if (findOps(name)) |found| {
        found.ops.addFn(self, entity, L, 3);
        updateLiveQueries(self, entity);
        return 0;
    }
    _ = lc.luaL_error(L, "unknown component: %s", lc.luaL_checklstring(L, 2, null));
    return 0;
}

fn luaGet(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const entity = getEntityOrError(self, L, 1) orelse return lc.lua_error(L);
    const name = componentName(L, 2);
    if (findOps(name)) |found| {
        return found.ops.getFn(self, entity, L);
    }
    _ = lc.luaL_error(L, "unknown component: %s", lc.luaL_checklstring(L, 2, null));
    return 0;
}

fn luaRemove(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const entity = getEntityOrError(self, L, 1) orelse return lc.lua_error(L);
    const name = componentName(L, 2);
    if (findOps(name)) |found| {
        found.ops.removeFn(&self.registry, entity);
        updateLiveQueries(self, entity);
        return 0;
    }
    _ = lc.luaL_error(L, "unknown component: %s", lc.luaL_checklstring(L, 2, null));
    return 0;
}

// ============================================================
// Live queries — persistent, self-updating entity sets
// ============================================================

pub const max_live_queries = 32;
const allocator = std.heap.c_allocator;

/// A persistent query that maintains a set of matching entities.
/// Updated incrementally when components are added/removed/destroyed.
pub const LiveQuery = struct {
    mask: u32 = 0, // bitmask over ops_table indices
    entities: std.ArrayListUnmanaged(u32) = .{},
    index_of: std.AutoHashMapUnmanaged(u32, u32) = .{}, // entity_id → dense index

    pub fn deinit(self: *LiveQuery) void {
        self.entities.deinit(allocator);
        self.index_of.deinit(allocator);
    }

    pub fn contains(self: *const LiveQuery, entity_id: u32) bool {
        return self.index_of.contains(entity_id);
    }

    pub fn add(self: *LiveQuery, entity_id: u32) void {
        if (self.index_of.contains(entity_id)) return;
        const idx: u32 = @intCast(self.entities.items.len);
        self.entities.append(allocator, entity_id) catch return;
        self.index_of.put(allocator, entity_id, idx) catch return;
    }

    pub fn remove(self: *LiveQuery, entity_id: u32) void {
        const idx = self.index_of.get(entity_id) orelse return;
        const last: u32 = @intCast(self.entities.items.len - 1);
        if (idx != last) {
            const moved = self.entities.items[last];
            self.entities.items[idx] = moved;
            self.index_of.putAssumeCapacity(moved, idx);
        }
        self.entities.items.len -= 1;
        _ = self.index_of.remove(entity_id);
    }

    pub fn data(self: *const LiveQuery) []const u32 {
        return self.entities.items;
    }
};

/// Check whether an entity has all components indicated by the mask.
fn entityMatchesMask(registry: *ecs.Registry, entity: ecs.Entity, mask: u32) bool {
    var m = mask;
    while (m != 0) {
        const bit: u5 = @intCast(@ctz(m));
        if (!ops_table[bit].hasFn(registry, entity)) return false;
        m &= m - 1;
    }
    return true;
}

/// After a component is added or removed, update all live queries for this entity.
fn updateLiveQueries(self: *Engine, entity: ecs.Entity) void {
    const entity_id: u32 = @bitCast(entity);
    for (self.live_queries[0..self.live_query_count]) |*lq| {
        const matches = entityMatchesMask(&self.registry, entity, lq.mask);
        const present = lq.contains(entity_id);
        if (matches and !present) {
            lq.add(entity_id);
        } else if (!matches and present) {
            lq.remove(entity_id);
        }
    }
}

/// Remove an entity from all live queries (called before destroy).
fn removeFromAllLiveQueries(self: *Engine, entity_id: u32) void {
    for (self.live_queries[0..self.live_query_count]) |*lq| {
        lq.remove(entity_id);
    }
}

// ============================================================
// Query — ad-hoc table builder (convenience API, not cached)
// ============================================================

fn resolveQueryOps(L: ?*lc.lua_State, ops: []ComponentOps, count: usize) bool {
    for (0..count) |i| {
        const name = std.mem.span(lc.luaL_checklstring(L, @intCast(i + 1), null));
        if (findOps(name)) |found| {
            ops[i] = found.ops;
        } else {
            _ = lc.luaL_error(L, "unknown component: %s", lc.luaL_checklstring(L, @intCast(i + 1), null));
            return false;
        }
    }
    return true;
}

fn findSmallestAndBuild(self: *Engine, L: ?*lc.lua_State, ops: []const ComponentOps, count: usize) void {
    var smallest_idx: usize = 0;
    var smallest_len: usize = ops[0].lenFn(&self.registry);
    for (1..count) |i| {
        const l = ops[i].lenFn(&self.registry);
        if (l < smallest_len) {
            smallest_len = l;
            smallest_idx = i;
        }
    }

    const entity_list = ops[smallest_idx].dataFn(&self.registry);
    lc.lua_createtable(L, @intCast(smallest_len), 0);
    var table_idx: c_int = 1;

    for (entity_list) |entity| {
        var match = true;
        for (0..count) |i| {
            if (i == smallest_idx) continue;
            if (!ops[i].hasFn(&self.registry, entity)) {
                match = false;
                break;
            }
        }
        if (match) {
            const entity_int: u32 = @bitCast(entity);
            lc.lua_pushinteger(L, @intCast(entity_int));
            lc.lua_rawseti(L, -2, table_idx);
            table_idx += 1;
        }
    }
}

fn luaQuery(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const nargs = lc.lua_gettop(L);
    if (nargs == 0) {
        _ = lc.luaL_error(L, "query requires at least one component name");
        return 0;
    }
    const count: usize = @intCast(nargs);
    if (count > 16) {
        _ = lc.luaL_error(L, "query supports at most 16 components");
        return 0;
    }

    var ops: [16]ComponentOps = undefined;
    if (!resolveQueryOps(L, &ops, count)) return 0;
    findSmallestAndBuild(self, L, ops[0..count], count);
    return 1;
}

// ============================================================
// Each — zero-allocation callback iterator
// ============================================================

fn luaEach(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const nargs = lc.lua_gettop(L);
    if (nargs < 2) {
        _ = lc.luaL_error(L, "each requires at least one component name and a callback");
        return 0;
    }

    // Last arg is callback
    lc.luaL_checktype(L, nargs, lc.LUA_TFUNCTION);
    const comp_count: usize = @intCast(nargs - 1);
    if (comp_count > 16) {
        _ = lc.luaL_error(L, "each supports at most 16 components");
        return 0;
    }

    var ops: [16]ComponentOps = undefined;
    for (0..comp_count) |i| {
        const name = std.mem.span(lc.luaL_checklstring(L, @intCast(i + 1), null));
        if (findOps(name)) |found| {
            ops[i] = found.ops;
        } else {
            _ = lc.luaL_error(L, "unknown component: %s", lc.luaL_checklstring(L, @intCast(i + 1), null));
            return 0;
        }
    }

    // Find smallest component set
    var smallest_idx: usize = 0;
    var smallest_len: usize = ops[0].lenFn(&self.registry);
    for (1..comp_count) |i| {
        const l = ops[i].lenFn(&self.registry);
        if (l < smallest_len) {
            smallest_len = l;
            smallest_idx = i;
        }
    }

    // Iterate and call callback per matching entity
    const entity_list = ops[smallest_idx].dataFn(&self.registry);
    for (entity_list) |entity| {
        var match = true;
        for (0..comp_count) |i| {
            if (i == smallest_idx) continue;
            if (!ops[i].hasFn(&self.registry, entity)) {
                match = false;
                break;
            }
        }
        if (match) {
            lc.lua_pushvalue(L, nargs); // push callback
            const entity_int: u32 = @bitCast(entity);
            lc.lua_pushinteger(L, @intCast(entity_int));
            // Use lua_call (not pcall) — errors propagate to the system-level
            // pcall in runLuaSystems, avoiding per-entity error handler overhead.
            lc.lua_call(L, 1, 0);
        }
    }

    return 0;
}

// ============================================================
// Persistent queries — create_query / each_query
// ============================================================

fn luaCreateQuery(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const nargs = lc.lua_gettop(L);
    if (nargs == 0) {
        _ = lc.luaL_error(L, "create_query requires at least one component name");
        return 0;
    }
    if (self.live_query_count >= max_live_queries) {
        _ = lc.luaL_error(L, "too many live queries (max %d)", @as(c_int, max_live_queries));
        return 0;
    }

    // Build mask and resolve ops for initial population
    var mask: u32 = 0;
    var ops: [16]ComponentOps = undefined;
    const count: usize = @intCast(nargs);
    if (count > 16) {
        _ = lc.luaL_error(L, "create_query supports at most 16 components");
        return 0;
    }
    for (0..count) |i| {
        const name = std.mem.span(lc.luaL_checklstring(L, @intCast(i + 1), null));
        if (findOps(name)) |found| {
            mask |= @as(u32, 1) << @as(u5, @intCast(found.index));
            ops[i] = found.ops;
        } else {
            _ = lc.luaL_error(L, "unknown component: %s", lc.luaL_checklstring(L, @intCast(i + 1), null));
            return 0;
        }
    }

    // Initialize
    const idx = self.live_query_count;
    self.live_queries[idx] = .{ .mask = mask };
    self.live_query_count += 1;

    // Populate with existing matching entities (iterate smallest set, filter)
    var smallest_idx: usize = 0;
    var smallest_len: usize = ops[0].lenFn(&self.registry);
    for (1..count) |i| {
        const l = ops[i].lenFn(&self.registry);
        if (l < smallest_len) {
            smallest_len = l;
            smallest_idx = i;
        }
    }
    const entity_list = ops[smallest_idx].dataFn(&self.registry);
    for (entity_list) |entity| {
        if (entityMatchesMask(&self.registry, entity, mask)) {
            self.live_queries[idx].add(@bitCast(entity));
        }
    }

    // Return 1-based handle
    lc.lua_pushinteger(L, @intCast(idx + 1));
    return 1;
}

fn luaEachQuery(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const handle: u32 = @intCast(lc.luaL_checkinteger(L, 1));
    lc.luaL_checktype(L, 2, lc.LUA_TFUNCTION);

    if (handle == 0 or handle > self.live_query_count) {
        _ = lc.luaL_error(L, "invalid query handle %d", @as(c_int, @intCast(handle)));
        return 0;
    }

    const entities = self.live_queries[handle - 1].data();
    for (entities) |entity_id| {
        lc.lua_pushvalue(L, 2);
        lc.lua_pushinteger(L, @intCast(entity_id));
        lc.lua_call(L, 1, 0);
    }
    return 0;
}

// ============================================================
// Component refs — vtable-dispatched field access
// ============================================================

fn luaRef(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const entity = getEntityOrError(self, L, 1) orelse return lc.lua_error(L);
    const entity_id: u32 = @bitCast(entity);
    const name = componentName(L, 2);

    if (findOps(name)) |found| {
        if (!found.ops.hasFn(&self.registry, entity)) {
            _ = lc.luaL_error(L, "entity %d has no component '%s'", @as(c_int, @intCast(entity_id)), lc.luaL_checklstring(L, 2, null));
            return 0;
        }
        const ptr: *ComponentRef = @ptrCast(@alignCast(lc.lua_newuserdata(L, @sizeOf(ComponentRef))));
        ptr.* = .{ .entity_id = entity_id, .ops_index = found.index };
        lc.luaL_getmetatable(L, ref_metatable_name);
        _ = lc.lua_setmetatable(L, -2);
        return 1;
    }
    _ = lc.luaL_error(L, "unknown component: %s", lc.luaL_checklstring(L, 2, null));
    return 0;
}

fn refIndex(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const ptr: *const ComponentRef = @ptrCast(@alignCast(lc.lua_touserdata(L, 1) orelse return 0));
    const field_name = std.mem.span(lc.luaL_checklstring(L, 2, null));
    const entity: ecs.Entity = @bitCast(ptr.entity_id);

    if (!self.registry.valid(entity)) {
        _ = lc.luaL_error(L, "stale ref: entity %d has been destroyed", @as(c_int, @intCast(ptr.entity_id)));
        return 0;
    }

    const ops = ops_table[ptr.ops_index];
    if (ops.refReadFn) |readFn| {
        const result = readFn(self, entity, field_name, L);
        if (result > 0) return result;
        _ = lc.luaL_error(L, "no field '%s' on component", lc.luaL_checklstring(L, 2, null));
        return 0;
    }
    // Tag component — return boolean presence
    lc.lua_pushboolean(L, if (ops.hasFn(&self.registry, entity)) 1 else 0);
    return 1;
}

fn refNewIndex(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const ptr: *const ComponentRef = @ptrCast(@alignCast(lc.lua_touserdata(L, 1) orelse return 0));
    const field_name = std.mem.span(lc.luaL_checklstring(L, 2, null));
    const entity: ecs.Entity = @bitCast(ptr.entity_id);

    if (!self.registry.valid(entity)) {
        _ = lc.luaL_error(L, "stale ref: entity %d has been destroyed", @as(c_int, @intCast(ptr.entity_id)));
        return 0;
    }

    const ops = ops_table[ptr.ops_index];
    if (ops.refWriteFn) |writeFn| {
        writeFn(self, entity, field_name, L);
    }
    return 0;
}

// ============================================================
// Input/scene callbacks (unchanged)
// ============================================================

fn luaCameraAxes(L: ?*lc.lua_State) callconv(.c) c_int {
    _ = getEngine(L);
    const v = checkVec3(L, 1);
    const axes = Engine.getCameraAxes(v[0], v[1], v[2]);
    pushVec3(L, axes.forward);
    pushVec3(L, axes.right);
    return 6;
}

fn luaMouseDelta(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const delta = self.getMouseDelta();
    lc.lua_pushnumber(L, delta.dx);
    lc.lua_pushnumber(L, delta.dy);
    return 2;
}

fn luaSetMouseGrab(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const grab = lc.lua_toboolean(L, 1) != 0;
    self.setMouseGrab(grab);
    return 0;
}

fn luaKeyDown(L: ?*lc.lua_State) callconv(.c) c_int {
    _ = getEngine(L);
    const name = lc.luaL_checklstring(L, 1, null);
    const scancode = c.SDL_GetScancodeFromName(name);
    const state = c.SDL_GetKeyboardState(null);
    lc.lua_pushboolean(L, if (state[scancode]) 1 else 0);
    return 1;
}

fn luaSetClearColor(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const rgb = checkVec3(L, 1);
    self.clear_color = rgb ++ .{1.0};
    return 0;
}

fn luaSetFog(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    if (lc.lua_isboolean(L, 1) and lc.lua_toboolean(L, 1) == 0) {
        self.fog_enabled = false;
        return 0;
    }
    self.fog_enabled = true;
    self.fog_start = checkFloat(L, 1);
    self.fog_end = checkFloat(L, 2);
    self.fog_color = optVec3(L, 3, .{ self.clear_color[0], self.clear_color[1], self.clear_color[2] });
    return 0;
}

fn luaSetAmbient(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const rgb = checkVec3(L, 1);
    self.ambient_color = rgb ++ .{0.0};
    return 0;
}

/// lunatic.set_bloom(entity, intensity, exposure)
/// Sets bloom parameters on a camera entity's Camera component.
/// intensity = 0 disables bloom (just tonemapping).
fn luaSetBloom(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const entity = getEntityOrError(self, L, 1) orelse return lc.lua_error(L);
    const cam = self.registry.tryGet(engine_mod.core_components.Camera, entity) orelse {
        _ = lc.luaL_error(L, "set_bloom: entity has no camera component");
        unreachable;
    };
    const nargs = lc.lua_gettop(L);
    if (nargs >= 2) cam.bloom_intensity = checkFloat(L, 2);
    if (nargs >= 3) cam.exposure = checkFloat(L, 3);
    return 0;
}

const postprocess = engine_mod.postprocess;

/// lunatic.get_bloom_tints() → t1, t2, t3, t4, t5, t6
fn luaGetBloomTints(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    for (self.postprocess.tints[0..postprocess.max_mip_levels]) |t| {
        lc.lua_pushnumber(L, t);
    }
    return postprocess.max_mip_levels;
}

/// lunatic.set_bloom_tints(t1, t2, t3, t4, t5, t6)
fn luaSetBloomTints(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const nargs = lc.lua_gettop(L);
    var i: u32 = 0;
    while (i < postprocess.max_mip_levels and i < nargs) : (i += 1) {
        self.postprocess.tints[i] = @floatCast(lc.luaL_checknumber(L, @intCast(i + 1)));
    }
    return 0;
}

/// lunatic.get_bloom_radius() → radius
fn luaGetBloomRadius(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    lc.lua_pushnumber(L, self.postprocess.radius);
    return 1;
}

/// lunatic.set_bloom_radius(radius)
fn luaSetBloomRadius(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    self.postprocess.radius = checkFloat(L, 1);
    return 0;
}

/// lunatic.get_stats() → table { draw_calls, entities, physics_active, physics_total,
///                               time_systems_ms, time_render_ms }
fn luaGetStats(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const s = self.stats;
    lc.lua_newtable(L);

    lc.lua_pushnumber(L, @floatFromInt(s.draw_calls));
    lc.lua_setfield(L, -2, "draw_calls");
    lc.lua_pushnumber(L, @floatFromInt(s.entities_rendered));
    lc.lua_setfield(L, -2, "entities");
    lc.lua_pushnumber(L, @floatFromInt(s.physics_active));
    lc.lua_setfield(L, -2, "physics_active");
    lc.lua_pushnumber(L, @floatFromInt(s.physics_total));
    lc.lua_setfield(L, -2, "physics_total");
    const total_render = s.time_prepare_us + s.time_instances_us + s.time_scene_us + s.time_postprocess_us + s.time_imgui_us;
    lc.lua_pushnumber(L, @as(f64, @floatFromInt(total_render)) / 1000.0);
    lc.lua_setfield(L, -2, "time_render_ms");

    return 1;
}

// ============================================================
// Physics callbacks
// ============================================================

const phys = engine_mod.physics;

/// lunatic.physics_add_box(entity, half_x, half_y, half_z, motion_type)
/// motion_type: "static", "dynamic", "kinematic" (default: "dynamic")
/// Creates a Jolt box body and sets the entity's rigid_body component.
fn luaPhysicsAddBox(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const entity = getEntityOrError(self, L, 1) orelse return lc.lua_error(L);
    const hx = checkFloat(L, 2);
    const hy = checkFloat(L, 3);
    const hz = checkFloat(L, 4);
    const motion = luaMotionType(L, 5);

    const pos = self.registry.getConst(core_comp.Position, entity);
    const shape_settings = phys.BoxShapeSettings.create(.{ hx, hy, hz }) catch return 0;
    const shape = shape_settings.asShapeSettings().createShape() catch return 0;
    defer shape.release();

    const nargs = lc.lua_gettop(L);
    const restitution: f32 = if (nargs >= 6) checkFloat(L, 6) else 0.0;
    const friction: f32 = if (nargs >= 7) checkFloat(L, 7) else 0.2;

    const body_iface = phys.getBodyInterface(self);
    const body_id = body_iface.createAndAddBody(.{
        .position = .{ pos.x, pos.y, pos.z, 0 },
        .shape = shape,
        .motion_type = motion,
        .object_layer = if (motion == .static) phys.object_layers.non_moving else phys.object_layers.moving,
        .restitution = restitution,
        .friction = friction,
        .linear_damping = 0.2,
        .angular_damping = 0.4,
    }, .activate) catch return 0;

    self.registry.addOrReplace(entity, core_comp.RigidBody{ .body_id = @intFromEnum(body_id) });
    return 0;
}

/// lunatic.physics_add_sphere(entity, radius, motion_type, restitution, friction)
fn luaPhysicsAddSphere(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const entity = getEntityOrError(self, L, 1) orelse return lc.lua_error(L);
    const radius = checkFloat(L, 2);
    const motion = luaMotionType(L, 3);
    const nargs = lc.lua_gettop(L);
    const restitution: f32 = if (nargs >= 4) checkFloat(L, 4) else 0.0;
    const friction: f32 = if (nargs >= 5) checkFloat(L, 5) else 0.2;

    const pos = self.registry.getConst(core_comp.Position, entity);
    const shape_settings = phys.SphereShapeSettings.create(radius) catch return 0;
    const shape = shape_settings.asShapeSettings().createShape() catch return 0;
    defer shape.release();

    const body_iface = phys.getBodyInterface(self);
    const body_id = body_iface.createAndAddBody(.{
        .position = .{ pos.x, pos.y, pos.z, 0 },
        .shape = shape,
        .motion_type = motion,
        .object_layer = if (motion == .static) phys.object_layers.non_moving else phys.object_layers.moving,
        .restitution = restitution,
        .friction = friction,
        .linear_damping = 0.2,
        .angular_damping = 0.4,
    }, .activate) catch return 0;

    self.registry.addOrReplace(entity, core_comp.RigidBody{ .body_id = @intFromEnum(body_id) });
    return 0;
}

/// lunatic.physics_add_floor(y) — static infinite floor at given y height
fn luaPhysicsAddFloor(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const nargs = lc.lua_gettop(L);
    const hx: f32 = if (nargs >= 1) checkFloat(L, 1) else 50;
    const hz: f32 = if (nargs >= 2) checkFloat(L, 2) else 50;
    const y: f32 = if (nargs >= 3) checkFloat(L, 3) else 0;

    const shape_settings = phys.BoxShapeSettings.create(.{ hx, 0.5, hz }) catch return 0;
    const shape = shape_settings.asShapeSettings().createShape() catch return 0;
    defer shape.release();

    const body_iface = phys.getBodyInterface(self);
    _ = body_iface.createAndAddBody(.{
        .position = .{ 0, y - 0.5, 0, 0 },
        .shape = shape,
        .motion_type = .static,
        .object_layer = phys.object_layers.non_moving,
    }, .dont_activate) catch return 0;

    return 0;
}

/// lunatic.physics_optimize() — call after adding static bodies
fn luaPhysicsOptimize(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    if (self.physics.system) |sys| sys.optimizeBroadPhase();
    return 0;
}

const core_comp = engine_mod.core_components;

fn luaMotionType(L: ?*lc.lua_State, idx: c_int) phys.MotionType {
    if (lc.lua_type(L, idx) != lc.LUA_TSTRING) return .dynamic;
    const s = std.mem.span(lc.luaL_checklstring(L, idx, null));
    if (std.mem.eql(u8, s, "static")) return .static;
    if (std.mem.eql(u8, s, "kinematic")) return .kinematic;
    return .dynamic;
}

// ============================================================
// ImGui UI callbacks (no engine upvalue — pure ImGui wrappers)
// ============================================================

const ig = engine_mod.c;

fn luaUiBegin(L: ?*lc.lua_State) callconv(.c) c_int {
    const name = lc.luaL_checklstring(L, 1, null);
    _ = ig.igBegin(name, null, 0);
    return 0;
}

fn luaUiEnd(_: ?*lc.lua_State) callconv(.c) c_int {
    ig.igEnd();
    return 0;
}

fn luaUiText(L: ?*lc.lua_State) callconv(.c) c_int {
    const text = lc.luaL_checklstring(L, 1, null);
    ig.igTextUnformatted(text);
    return 0;
}

fn luaUiSeparatorText(L: ?*lc.lua_State) callconv(.c) c_int {
    const text = lc.luaL_checklstring(L, 1, null);
    ig.igSeparatorText(text);
    return 0;
}

/// ui.slider_float(label, current_value, min, max) → new_value
fn luaUiSliderFloat(L: ?*lc.lua_State) callconv(.c) c_int {
    const label = lc.luaL_checklstring(L, 1, null);
    var value: f32 = @floatCast(lc.luaL_checknumber(L, 2));
    const min: f32 = @floatCast(lc.luaL_checknumber(L, 3));
    const max: f32 = @floatCast(lc.luaL_checknumber(L, 4));
    _ = ig.igSliderFloat(label, &value, min, max);
    lc.lua_pushnumber(L, value);
    return 1;
}

/// ui.checkbox(label, current_value) → new_value
fn luaUiCheckbox(L: ?*lc.lua_State) callconv(.c) c_int {
    const label = lc.luaL_checklstring(L, 1, null);
    var checked: bool = lc.lua_toboolean(L, 2) != 0;
    _ = ig.igCheckbox(label, &checked);
    lc.lua_pushboolean(L, if (checked) 1 else 0);
    return 1;
}

/// ui.button(label) → was_clicked
fn luaUiButton(L: ?*lc.lua_State) callconv(.c) c_int {
    const label = lc.luaL_checklstring(L, 1, null);
    const clicked = ig.igButton(label);
    lc.lua_pushboolean(L, if (clicked) 1 else 0);
    return 1;
}

/// ui.collapsing_header(label) → is_open
fn luaUiCollapsingHeader(L: ?*lc.lua_State) callconv(.c) c_int {
    const label = lc.luaL_checklstring(L, 1, null);
    const open = ig.igCollapsingHeader(label, 0);
    lc.lua_pushboolean(L, if (open) 1 else 0);
    return 1;
}

/// ui.set_next_window_pos(x, y, cond) — cond: "always", "once", "first_use"
fn luaUiSetNextWindowPos(L: ?*lc.lua_State) callconv(.c) c_int {
    const x: f32 = @floatCast(lc.luaL_checknumber(L, 1));
    const y: f32 = @floatCast(lc.luaL_checknumber(L, 2));
    const cond = luaUiCond(L, 3);
    ig.igSetNextWindowPos(.{ .x = x, .y = y }, cond);
    return 0;
}

/// ui.set_next_window_size(w, h, cond)
fn luaUiSetNextWindowSize(L: ?*lc.lua_State) callconv(.c) c_int {
    const w: f32 = @floatCast(lc.luaL_checknumber(L, 1));
    const h: f32 = @floatCast(lc.luaL_checknumber(L, 2));
    const cond = luaUiCond(L, 3);
    ig.igSetNextWindowSize(.{ .x = w, .y = h }, cond);
    return 0;
}

/// ui.fps() → current framerate
fn luaUiFps(L: ?*lc.lua_State) callconv(.c) c_int {
    const io = ig.igGetIO();
    lc.lua_pushnumber(L, if (io) |i| i.*.Framerate else 0);
    return 1;
}

fn luaUiCond(L: ?*lc.lua_State, idx: c_int) c_int {
    if (lc.lua_type(L, idx) != lc.LUA_TSTRING) return 0;
    const s = std.mem.span(lc.luaL_checklstring(L, idx, null));
    if (std.mem.eql(u8, s, "always")) return ig.ImGuiCond_Always;
    if (std.mem.eql(u8, s, "once")) return ig.ImGuiCond_Once;
    if (std.mem.eql(u8, s, "first_use")) return ig.ImGuiCond_FirstUseEver;
    return 0;
}

// ============================================================
// Asset creation callbacks (unchanged)
// ============================================================

fn luaCreateCubeMesh(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const id = self.createCubeMesh() catch {
        _ = lc.luaL_error(L, "failed to create cube mesh");
        unreachable;
    };
    lc.lua_pushinteger(L, @intCast(id));
    return 1;
}

fn luaCreateSphereMesh(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const segments: u32 = if (lc.lua_type(L, 1) == lc.LUA_TTABLE) blk: {
        lc.lua_getfield(L, 1, "segments");
        const s: u32 = @intCast(lc.luaL_optinteger(L, -1, 32));
        lc.lua_pop(L, 1);
        break :blk s;
    } else 32;
    const rings: u32 = if (lc.lua_type(L, 1) == lc.LUA_TTABLE) blk: {
        lc.lua_getfield(L, 1, "rings");
        const r: u32 = @intCast(lc.luaL_optinteger(L, -1, 16));
        lc.lua_pop(L, 1);
        break :blk r;
    } else 16;
    const id = self.createSphereMesh(segments, rings) catch {
        _ = lc.luaL_error(L, "failed to create sphere mesh");
        unreachable;
    };
    lc.lua_pushinteger(L, @intCast(id));
    return 1;
}

fn luaCreateMaterial(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    lc.luaL_checktype(L, 1, lc.LUA_TTABLE);

    var data = engine_mod.MaterialData{};

    lc.lua_getfield(L, 1, "albedo");
    if (lc.lua_type(L, -1) == lc.LUA_TTABLE) {
        lc.lua_rawgeti(L, -1, 1);
        data.albedo[0] = @floatCast(lc.luaL_optnumber(L, -1, 1.0));
        lc.lua_pop(L, 1);
        lc.lua_rawgeti(L, -1, 2);
        data.albedo[1] = @floatCast(lc.luaL_optnumber(L, -1, 1.0));
        lc.lua_pop(L, 1);
        lc.lua_rawgeti(L, -1, 3);
        data.albedo[2] = @floatCast(lc.luaL_optnumber(L, -1, 1.0));
        lc.lua_pop(L, 1);
    }
    lc.lua_pop(L, 1);

    lc.lua_getfield(L, 1, "metallic");
    if (lc.lua_type(L, -1) == lc.LUA_TNUMBER) {
        data.metallic = @floatCast(lc.lua_tonumber(L, -1));
    }
    lc.lua_pop(L, 1);

    lc.lua_getfield(L, 1, "roughness");
    if (lc.lua_type(L, -1) == lc.LUA_TNUMBER) {
        data.roughness = @floatCast(lc.lua_tonumber(L, -1));
    }
    lc.lua_pop(L, 1);

    lc.lua_getfield(L, 1, "emissive");
    if (lc.lua_type(L, -1) == lc.LUA_TTABLE) {
        lc.lua_rawgeti(L, -1, 1);
        data.emissive[0] = @floatCast(lc.luaL_optnumber(L, -1, 0.0));
        lc.lua_pop(L, 1);
        lc.lua_rawgeti(L, -1, 2);
        data.emissive[1] = @floatCast(lc.luaL_optnumber(L, -1, 0.0));
        lc.lua_pop(L, 1);
        lc.lua_rawgeti(L, -1, 3);
        data.emissive[2] = @floatCast(lc.luaL_optnumber(L, -1, 0.0));
        lc.lua_pop(L, 1);
    }
    lc.lua_pop(L, 1);

    const id = self.createMaterial(data) catch {
        _ = lc.luaL_error(L, "too many materials");
        unreachable;
    };
    lc.lua_pushinteger(L, @intCast(id));
    return 1;
}

fn luaLoadGltf(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const path = lc.luaL_checklstring(L, 1, null);

    var model = gltf_mod.load(self, path) catch {
        _ = lc.luaL_error(L, "failed to load gltf: %s", path);
        unreachable;
    };
    defer model.deinit();

    // Return table: { meshes = { id, id, ... }, materials = { id, id, ... } }
    lc.lua_newtable(L);

    // meshes array
    lc.lua_newtable(L);
    for (model.mesh_ids, 0..) |id, i| {
        lc.lua_pushinteger(L, @intCast(id));
        lc.lua_rawseti(L, -2, @intCast(i + 1));
    }
    lc.lua_setfield(L, -2, "meshes");

    // materials array
    lc.lua_newtable(L);
    for (model.material_ids, 0..) |id, i| {
        lc.lua_pushinteger(L, @intCast(id));
        lc.lua_rawseti(L, -2, @intCast(i + 1));
    }
    lc.lua_setfield(L, -2, "materials");

    return 1;
}

fn luaSystemRegister(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const name = lc.luaL_checklstring(L, 1, null);
    lc.luaL_checktype(L, 2, lc.LUA_TFUNCTION);

    lc.lua_pushvalue(L, 2);
    const ref = lc.luaL_ref(L, lc.LUA_REGISTRYINDEX);

    if (self.system_count >= engine_mod.max_systems) {
        _ = lc.luaL_error(L, "too many systems");
        return 0;
    }

    self.addLuaSystem(name, ref);
    return 0;
}
