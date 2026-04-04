// lua_api.zig — Lua C callbacks and API registration.

const std = @import("std");
const builtin = @import("builtin");
const components = @import("components.zig");
const ecs = @import("zig-ecs");
const engine_mod = @import("engine.zig");
const Engine = engine_mod.Engine;
const c = engine_mod.c;
const gltf_mod = engine_mod.gltf;

const lua = @import("lua.zig");
const lc = lua.c;

const Position = components.Position;
const Rotation = components.Rotation;
const MeshHandle = components.MeshHandle;
const MaterialHandle = components.MaterialHandle;
const LookAt = components.LookAt;

// ============================================================
// Query infrastructure
// ============================================================

pub const QueryCacheEntry = struct {
    lua_ref: c_int = lc.LUA_NOREF,
    frame: u64 = 0,
    hash: u64 = 0,
};

pub const max_cached_queries = 64;

const ComponentRef = extern struct {
    entity_id: u32,
    type_tag: u8,
};

const ref_metatable_name: [*:0]const u8 = "lunatic_component_ref";

const HasFn = *const fn (*ecs.Registry, ecs.Entity) bool;
const LenFn = *const fn (*ecs.Registry) usize;
const DataFn = *const fn (*ecs.Registry) []ecs.Entity;

const QueryEntry = struct {
    name: []const u8,
    hasFn: HasFn,
    lenFn: LenFn,
    dataFn: DataFn,
};

fn makeQueryEntries() [components.all.len]QueryEntry {
    var entries: [components.all.len]QueryEntry = undefined;
    inline for (components.all, 0..) |T, i| {
        entries[i] = .{
            .name = lua.nameOf(T),
            .hasFn = &struct {
                fn has(reg: *ecs.Registry, entity: ecs.Entity) bool {
                    return reg.has(T, entity);
                }
            }.has,
            .lenFn = &struct {
                fn len(reg: *ecs.Registry) usize {
                    return reg.len(T);
                }
            }.len,
            .dataFn = &struct {
                fn data(reg: *ecs.Registry) []ecs.Entity {
                    return reg.data(T);
                }
            }.data,
        };
    }
    return entries;
}

const query_entries = makeQueryEntries();

fn findQueryEntry(name: []const u8) ?QueryEntry {
    for (query_entries) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry;
    }
    return null;
}

fn queryHash(entries: []const QueryEntry, count: usize) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (0..count) |i| {
        for (entries[i].name) |byte| {
            h ^= byte;
            h *%= 0x100000001b3;
        }
        h ^= 0xff;
        h *%= 0x100000001b3;
    }
    return h;
}

// ============================================================
// Query cache helpers (operate on Engine fields)
// ============================================================

fn findCachedQuery(self: *Engine, hash: u64) ?usize {
    for (0..max_cached_queries) |i| {
        if (self.query_cache[i].hash == hash and self.query_cache[i].frame == self.current_frame) {
            return i;
        }
    }
    return null;
}

fn findCacheSlot(self: *Engine, hash: u64) usize {
    for (0..max_cached_queries) |i| {
        if (self.query_cache[i].hash == hash) return i;
    }
    var oldest_idx: usize = 0;
    var oldest_frame: u64 = std.math.maxInt(u64);
    for (0..max_cached_queries) |i| {
        if (self.query_cache[i].lua_ref == lc.LUA_NOREF) return i;
        if (self.query_cache[i].frame < oldest_frame) {
            oldest_frame = self.query_cache[i].frame;
            oldest_idx = i;
        }
    }
    if (self.query_cache[oldest_idx].lua_ref != lc.LUA_NOREF) {
        if (self.lua_state) |L| {
            lc.luaL_unref(L, lc.LUA_REGISTRYINDEX, self.query_cache[oldest_idx].lua_ref);
        }
        self.query_cache[oldest_idx].lua_ref = lc.LUA_NOREF;
    }
    return oldest_idx;
}

fn buildQueryTable(self: *Engine, L: ?*lc.lua_State, entries: []const QueryEntry, count: usize) void {
    var smallest_idx: usize = 0;
    var smallest_len: usize = entries[0].lenFn(&self.registry);
    for (1..count) |i| {
        const l = entries[i].lenFn(&self.registry);
        if (l < smallest_len) {
            smallest_len = l;
            smallest_idx = i;
        }
    }

    const entity_list = entries[smallest_idx].dataFn(&self.registry);
    lc.lua_createtable(L, @intCast(smallest_len), 0);
    var table_idx: c_int = 1;

    for (entity_list) |entity| {
        var match = true;
        for (0..count) |i| {
            if (i == smallest_idx) continue;
            if (!entries[i].hasFn(&self.registry, entity)) {
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
    for (0..self.mesh_count) |i| {
        if (self.mesh_names[i]) |name| {
            lc.lua_pushinteger(L, @intCast(i));
            lc.lua_setfield(L, -2, name);
        }
    }
    lc.lua_setfield(L, -2, "mesh");

    lc.lua_newtable(L);
    for (0..self.material_count) |i| {
        if (self.material_names[i]) |name| {
            lc.lua_pushinteger(L, @intCast(i));
            lc.lua_setfield(L, -2, name);
        }
    }
    lc.lua_setfield(L, -2, "material");

    lc.lua_pop(L, 1);
}

// ============================================================
// Lua C callbacks
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

const HandleKind = enum { mesh, material };

fn resolveHandle(self: *Engine, L: ?*lc.lua_State, idx: c_int, kind: HandleKind) u32 {
    if (lc.lua_type(L, idx) == lc.LUA_TNUMBER) {
        return @intCast(lc.lua_tointeger(L, idx));
    }
    const name = lc.luaL_checklstring(L, idx, null);
    const id = switch (kind) {
        .mesh => self.findMesh(name),
        .material => self.findMaterial(name),
    };
    if (id) |found| return found;
    const label = switch (kind) {
        .mesh => "unknown mesh: %s",
        .material => "unknown material: %s",
    };
    _ = lc.luaL_error(L, label, name);
    unreachable;
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
// Lua C callbacks
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

    const id = self.createMaterial(data) catch {
        _ = lc.luaL_error(L, "too many materials");
        unreachable;
    };
    lc.lua_pushinteger(L, @intCast(id));
    return 1;
}

fn luaSpawn(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const entity = self.registry.create();
    self.current_frame +%= 1; // invalidate query cache
    const entity_int: u32 = @bitCast(entity);
    lc.lua_pushinteger(L, @intCast(entity_int));
    return 1;
}

fn luaDestroy(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const entity = entityFromLua(self, L, 1);
    self.registry.destroy(entity);
    self.current_frame +%= 1; // invalidate query cache
    return 0;
}

fn luaAdd(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const entity = entityFromLua(self, L, 1);
    const name = componentName(L, 2);

    inline for (components.all) |T| {
        if (std.mem.eql(u8, name, lua.nameOf(T))) {
            if (comptime lua.isTag(T)) {
                self.registry.addOrReplace(entity, T{});
                return 0;
            } else if (comptime @hasDecl(T, "Lua")) {
                self.registry.addOrReplace(entity, T.Lua.fromLua(L, 3));
                return 0;
            }
        }
    }

    if (std.mem.eql(u8, name, lua.nameOf(MeshHandle))) {
        const mesh_id = resolveHandle(self, L, 3, .mesh);
        self.registry.addOrReplace(entity, MeshHandle{ .id = mesh_id });
        return 0;
    }

    if (std.mem.eql(u8, name, lua.nameOf(MaterialHandle))) {
        const mat_id = resolveHandle(self, L, 3, .material);
        self.registry.addOrReplace(entity, MaterialHandle{ .id = mat_id });
        return 0;
    }

    if (std.mem.eql(u8, name, lua.nameOf(LookAt))) {
        const target_id: u32 = @intCast(lc.luaL_checkinteger(L, 3));
        self.registry.addOrReplace(entity, LookAt{ .target = target_id });
        return 0;
    }

    _ = lc.luaL_error(L, "unknown component: %s", lc.luaL_checklstring(L, 2, null));
    return 0;
}

fn luaGet(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const entity = entityFromLua(self, L, 1);
    const name = componentName(L, 2);

    inline for (components.all) |T| {
        if (std.mem.eql(u8, name, lua.nameOf(T))) {
            if (comptime lua.isTag(T)) {
                lc.lua_pushboolean(L, if (self.registry.has(T, entity)) 1 else 0);
                return 1;
            } else if (comptime @hasDecl(T, "Lua")) {
                if (self.registry.tryGet(T, entity)) |val| {
                    return T.Lua.toLua(val.*, L);
                }
                return 0;
            }
        }
    }

    // Handle types without auto-bindings
    if (std.mem.eql(u8, name, lua.nameOf(components.MeshHandle))) {
        if (self.registry.tryGet(components.MeshHandle, entity)) |mh| {
            lc.lua_pushinteger(L, @intCast(mh.id));
            return 1;
        }
        return 0;
    }
    if (std.mem.eql(u8, name, lua.nameOf(components.MaterialHandle))) {
        if (self.registry.tryGet(components.MaterialHandle, entity)) |mh| {
            lc.lua_pushinteger(L, @intCast(mh.id));
            return 1;
        }
        return 0;
    }
    if (std.mem.eql(u8, name, lua.nameOf(components.LookAt))) {
        if (self.registry.tryGet(components.LookAt, entity)) |la| {
            lc.lua_pushinteger(L, @intCast(la.target));
            return 1;
        }
        return 0;
    }

    _ = lc.luaL_error(L, "unknown component: %s", lc.luaL_checklstring(L, 2, null));
    return 0;
}

fn luaRemove(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const entity = entityFromLua(self, L, 1);
    const name = componentName(L, 2);

    inline for (components.all) |T| {
        if (std.mem.eql(u8, name, lua.nameOf(T))) {
            self.registry.remove(T, entity);
            return 0;
        }
    }

    _ = lc.luaL_error(L, "unknown component: %s", lc.luaL_checklstring(L, 2, null));
    return 0;
}

fn luaQuery(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const nargs = lc.lua_gettop(L);
    if (nargs == 0) {
        _ = lc.luaL_error(L, "query requires at least one component name");
        return 0;
    }

    var entries: [16]QueryEntry = undefined;
    const count: usize = @intCast(nargs);
    if (count > 16) {
        _ = lc.luaL_error(L, "query supports at most 16 components");
        return 0;
    }

    for (0..count) |i| {
        const name = std.mem.span(lc.luaL_checklstring(L, @intCast(i + 1), null));
        entries[i] = findQueryEntry(name) orelse {
            _ = lc.luaL_error(L, "unknown component: %s", lc.luaL_checklstring(L, @intCast(i + 1), null));
            return 0;
        };
    }

    std.mem.sort(QueryEntry, entries[0..count], {}, struct {
        fn lessThan(_: void, a: QueryEntry, b: QueryEntry) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);

    const hash = queryHash(&entries, count);

    if (findCachedQuery(self, hash)) |idx| {
        lc.lua_rawgeti(L, lc.LUA_REGISTRYINDEX, self.query_cache[idx].lua_ref);
        return 1;
    }

    buildQueryTable(self, L, &entries, count);

    lc.lua_pushvalue(L, -1);
    const slot = findCacheSlot(self, hash);
    if (self.query_cache[slot].lua_ref != lc.LUA_NOREF) {
        lc.luaL_unref(L, lc.LUA_REGISTRYINDEX, self.query_cache[slot].lua_ref);
    }
    self.query_cache[slot] = .{
        .lua_ref = lc.luaL_ref(L, lc.LUA_REGISTRYINDEX),
        .frame = self.current_frame,
        .hash = hash,
    };

    return 1;
}

fn luaRef(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const entity = entityFromLua(self, L, 1);
    const entity_id: u32 = @bitCast(entity);
    const name = componentName(L, 2);

    inline for (components.all, 0..) |T, i| {
        if (std.mem.eql(u8, name, lua.nameOf(T))) {
            if (!self.registry.has(T, entity)) {
                _ = lc.luaL_error(L, "entity %d has no component '%s'", @as(c_int, @intCast(entity_id)), lc.luaL_checklstring(L, 2, null));
                return 0;
            }

            const ptr: *ComponentRef = @ptrCast(@alignCast(lc.lua_newuserdata(L, @sizeOf(ComponentRef))));
            ptr.* = .{ .entity_id = entity_id, .type_tag = @intCast(i) };
            lc.luaL_getmetatable(L, ref_metatable_name);
            _ = lc.lua_setmetatable(L, -2);
            return 1;
        }
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

    inline for (components.all, 0..) |T, i| {
        if (ptr.type_tag == i) {
            if (comptime lua.isTag(T)) {
                lc.lua_pushboolean(L, if (self.registry.has(T, entity)) 1 else 0);
                return 1;
            } else if (self.registry.tryGet(T, entity)) |val| {
                inline for (std.meta.fields(T)) |field| {
                    if (std.mem.eql(u8, field_name, field.name)) {
                        const fval = @field(val.*, field.name);
                        if (comptime field.type == f32) {
                            lc.lua_pushnumber(L, fval);
                        } else if (comptime field.type == u32) {
                            lc.lua_pushinteger(L, @intCast(fval));
                        }
                        return 1;
                    }
                }
                _ = lc.luaL_error(L, "no field '%s' on component", lc.luaL_checklstring(L, 2, null));
                return 0;
            }
            return 0;
        }
    }
    return 0;
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

    inline for (components.all, 0..) |T, i| {
        if (ptr.type_tag == i) {
            if (comptime !lua.isTag(T)) {
                if (self.registry.tryGet(T, entity)) |comp| {
                    inline for (std.meta.fields(T)) |field| {
                        if (std.mem.eql(u8, field_name, field.name)) {
                            if (comptime field.type == f32) {
                                @field(comp, field.name) = @floatCast(lc.luaL_checknumber(L, 3));
                            } else if (comptime field.type == u32) {
                                @field(comp, field.name) = @intCast(lc.luaL_checkinteger(L, 3));
                            }
                            return 0;
                        }
                    }
                    _ = lc.luaL_error(L, "no field '%s' on component", lc.luaL_checklstring(L, 2, null));
                }
            }
            return 0;
        }
    }
    return 0;
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
