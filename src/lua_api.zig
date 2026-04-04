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
        .{ "spawn", &luaSpawn },
        .{ "destroy", &luaDestroy },
        .{ "add", &luaAdd },
        .{ "get", &luaGet },
        .{ "remove", &luaRemove },
        .{ "query", &luaQuery },
        .{ "each", &luaEach },
        .{ "ref", &luaRef },
        .{ "create_material", &luaCreateMaterial },
        .{ "create_cube_mesh", &luaCreateCubeMesh },
        .{ "create_sphere_mesh", &luaCreateSphereMesh },
        .{ "load_gltf", &luaLoadGltf },
        .{ "system", &luaSystemRegister },
    };

    inline for (fns) |entry| {
        lc.lua_pushlightuserdata(L, self_ptr);
        lc.lua_pushcclosure(L, entry[1], 1);
        lc.lua_setfield(L, -2, entry[0]);
    }

    lc.lua_setglobal(L, "lunatic");

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

fn entityFromLua(self: *Engine, L: ?*lc.lua_State, idx: c_int) ecs.Entity {
    const id: u32 = @intCast(lc.luaL_checkinteger(L, idx));
    const entity: ecs.Entity = @bitCast(id);
    if (!self.registry.valid(entity)) {
        _ = lc.luaL_error(L, "invalid entity %d", @as(c_int, @intCast(id)));
    }
    return entity;
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
    const entity = entityFromLua(self, L, 1);
    self.registry.destroy(entity);
    return 0;
}

fn luaAdd(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const entity = entityFromLua(self, L, 1);
    const name = componentName(L, 2);
    if (findOps(name)) |found| {
        found.ops.addFn(self, entity, L, 3);
        return 0;
    }
    _ = lc.luaL_error(L, "unknown component: %s", lc.luaL_checklstring(L, 2, null));
    return 0;
}

fn luaGet(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const entity = entityFromLua(self, L, 1);
    const name = componentName(L, 2);
    if (findOps(name)) |found| {
        return found.ops.getFn(self, entity, L);
    }
    _ = lc.luaL_error(L, "unknown component: %s", lc.luaL_checklstring(L, 2, null));
    return 0;
}

fn luaRemove(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const entity = entityFromLua(self, L, 1);
    const name = componentName(L, 2);
    if (findOps(name)) |found| {
        found.ops.removeFn(&self.registry, entity);
        return 0;
    }
    _ = lc.luaL_error(L, "unknown component: %s", lc.luaL_checklstring(L, 2, null));
    return 0;
}

// ============================================================
// Query — cacheless table builder
// ============================================================

fn luaQuery(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const nargs = lc.lua_gettop(L);
    if (nargs == 0) {
        _ = lc.luaL_error(L, "query requires at least one component name");
        return 0;
    }

    var ops: [16]ComponentOps = undefined;
    const count: usize = @intCast(nargs);
    if (count > 16) {
        _ = lc.luaL_error(L, "query supports at most 16 components");
        return 0;
    }

    for (0..count) |i| {
        const name = std.mem.span(lc.luaL_checklstring(L, @intCast(i + 1), null));
        if (findOps(name)) |found| {
            ops[i] = found.ops;
        } else {
            _ = lc.luaL_error(L, "unknown component: %s", lc.luaL_checklstring(L, @intCast(i + 1), null));
            return 0;
        }
    }

    // Find smallest component set to iterate
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
            if (lc.lua_pcall(L, 1, 0, 0) != 0) {
                return lc.lua_error(L);
            }
        }
    }

    return 0;
}

// ============================================================
// Component refs — vtable-dispatched field access
// ============================================================

fn luaRef(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const entity = entityFromLua(self, L, 1);
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
    _ = lc.luaL_checklstring(L, 1, null);
    lc.luaL_checktype(L, 2, lc.LUA_TFUNCTION);

    lc.lua_pushvalue(L, 2);
    const ref = lc.luaL_ref(L, lc.LUA_REGISTRYINDEX);

    if (self.lua_system_count >= engine_mod.max_lua_systems) {
        _ = lc.luaL_error(L, "too many Lua systems (max 64)");
        return 0;
    }

    self.lua_system_refs[self.lua_system_count] = ref;
    self.lua_system_count += 1;
    return 0;
}
