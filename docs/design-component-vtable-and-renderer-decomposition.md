# Design: Component Vtable, Query Simplification, Renderer Decomposition

**Status:** Proposed  
**Date:** 2026-04-04  
**Scope:** `lua.zig`, `core_components.zig`, `components.zig`, `lua_api.zig`, `engine.zig`, `renderer.zig`

---

## Overview

Five interconnected refactorings that reconceive how components interact with the Lua bridge and how the renderer is structured. Implemented in three phases:

1. **Component metadata + vtable + asset handle crystallization** (suggestions 1, 2, 5)
2. **Query cache elimination** (suggestion 4)
3. **Renderer decomposition** (suggestion 3)

---

## Phase 1: Component Vtable

### 1.1 New component metadata format

Every component declares a `pub const lua` struct literal with its Lua bridge semantics. This replaces both `pub const Lua = lua.Component(...)` and `pub const lua_name = "..."`.

**core_components.zig** (after):

```zig
const lua_bind = @import("lua");

pub const Position = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    pub const lua = .{ .name = "position" };
};

pub const Rotation = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    pub const lua = .{ .name = "rotation" };
};

pub const Scale = struct {
    x: f32 = 1,
    y: f32 = 1,
    z: f32 = 1,
    pub const lua = .{ .name = "scale" };
};

pub const MeshHandle = struct {
    id: u32 = 0,
    pub const lua = .{ .name = "mesh", .resolve = .mesh };
};

pub const MaterialHandle = struct {
    id: u32 = 0,
    pub const lua = .{ .name = "material", .resolve = .material };
};

pub const Camera = struct {
    fov: f32 = 60,
    near: f32 = 0.1,
    far: f32 = 100.0,
    viewport_x: f32 = 0.0,
    viewport_y: f32 = 0.0,
    viewport_w: f32 = 1.0,
    viewport_h: f32 = 1.0,
    pub const lua = .{ .name = "camera" };
};

pub const DirectionalLight = struct {
    dir_x: f32 = 0.4,
    dir_y: f32 = 0.8,
    dir_z: f32 = 0.4,
    r: f32 = 1.0,
    g: f32 = 1.0,
    b: f32 = 1.0,
    pub const lua = .{ .name = "directional_light" };
};

pub const LookAt = struct {
    target: u32 = 0,
    pub const lua = .{ .name = "look_at" };
};

pub const all = .{ Position, Rotation, Scale, MeshHandle, MaterialHandle, Camera, DirectionalLight, LookAt };

pub fn withExtra(extra: anytype) @TypeOf(all ++ extra) {
    return all ++ extra;
}
```

**Key rules for `.lua` metadata:**

| Field | Type | Required | Meaning |
|-------|------|----------|---------|
| `.name` | `[]const u8` | yes | Lua-visible component name |
| `.resolve` | `enum { mesh, material }` | no | If present, `addFn` uses `resolveHandle` for string→ID resolution |

**Detection rules** (applied by vtable generator):
- **Tag component**: `@sizeOf(T) == 0`
- **Asset handle**: `T.lua` has `.resolve` field
- **Data component**: all other non-zero-sized structs; fields must be `f32` or `u32`

### 1.2 Changes to `lua.zig`

Remove:
- `pub fn Component(...)` — the auto-serializer return type
- `pub fn hasBindings(...)` — replaced by vtable presence
- `pub fn isTag(...)` — replaced by `@sizeOf(T) == 0` in generator

Keep (but simplify):
- `pub const c = @cImport(...)` — unchanged
- `pub fn nameOf(T)` — simplified to just read `T.lua.name`

Add:
- `pub const ComponentOps` — the vtable struct
- `pub fn makeComponentOps(comptime all: anytype) [all.len]ComponentOps` — the generator

**New `lua.zig`:**

```zig
const std = @import("std");

pub const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lualib.h");
    @cInclude("lauxlib.h");
});

const ecs = @import("zig-ecs");

// Forward-declare Engine to avoid circular imports.
// lua_api.zig passes the concrete Engine pointer at call sites.
const Engine = @import("engine").Engine;

/// Get the Lua name for any component type.
pub fn nameOf(comptime T: type) []const u8 {
    return T.lua.name;
}

/// Runtime vtable for one component type's Lua bridge operations.
pub const ComponentOps = struct {
    name: []const u8,

    // ECS query operations (used by query/each)
    hasFn: *const fn (*ecs.Registry, ecs.Entity) bool,
    lenFn: *const fn (*ecs.Registry) usize,
    dataFn: *const fn (*ecs.Registry) []ecs.Entity,

    // Lua bridge operations
    addFn: *const fn (*Engine, ecs.Entity, ?*c.lua_State, c_int) void,
    getFn: *const fn (*Engine, ecs.Entity, ?*c.lua_State) c_int,
    removeFn: *const fn (*ecs.Registry, ecs.Entity) void,

    // Component ref field access (null for tag components)
    refReadFn: ?*const fn (*Engine, ecs.Entity, []const u8, ?*c.lua_State) c_int,
    refWriteFn: ?*const fn (*Engine, ecs.Entity, []const u8, ?*c.lua_State) void,
};

/// Generate a ComponentOps vtable entry for each type in the `all` tuple.
pub fn makeComponentOps(comptime all: anytype) [all.len]ComponentOps {
    var ops: [all.len]ComponentOps = undefined;
    inline for (all, 0..) |T, i| {
        ops[i] = makeOpsForType(T);
    }
    return ops;
}

fn makeOpsForType(comptime T: type) ComponentOps {
    const is_tag = @sizeOf(T) == 0;
    const has_resolve = @hasField(@TypeOf(T.lua), "resolve");

    return .{
        .name = T.lua.name,

        .hasFn = &struct {
            fn f(reg: *ecs.Registry, entity: ecs.Entity) bool {
                return reg.has(T, entity);
            }
        }.f,
        .lenFn = &struct {
            fn f(reg: *ecs.Registry) usize {
                return reg.len(T);
            }
        }.f,
        .dataFn = &struct {
            fn f(reg: *ecs.Registry) []ecs.Entity {
                return reg.data(T);
            }
        }.f,

        .addFn = &struct {
            fn f(engine: *Engine, entity: ecs.Entity, L: ?*c.lua_State, base: c_int) void {
                if (comptime is_tag) {
                    engine.registry.addOrReplace(entity, T{});
                } else if (comptime has_resolve) {
                    const id = engine.resolveHandle(L, base, T.lua.resolve);
                    engine.registry.addOrReplace(entity, T{ .id = id });
                } else {
                    engine.registry.addOrReplace(entity, fromLua(T, L, base));
                }
            }
        }.f,

        .getFn = &struct {
            fn f(engine: *Engine, entity: ecs.Entity, L: ?*c.lua_State) c_int {
                if (comptime is_tag) {
                    c.lua_pushboolean(L, if (engine.registry.has(T, entity)) 1 else 0);
                    return 1;
                } else {
                    if (engine.registry.tryGet(T, entity)) |val| {
                        return toLua(T, val.*, L);
                    }
                    return 0;
                }
            }
        }.f,

        .removeFn = &struct {
            fn f(reg: *ecs.Registry, entity: ecs.Entity) void {
                reg.remove(T, entity);
            }
        }.f,

        .refReadFn = if (is_tag) null else &struct {
            fn f(engine: *Engine, entity: ecs.Entity, field_name: []const u8, L: ?*c.lua_State) c_int {
                if (engine.registry.tryGet(T, entity)) |val| {
                    inline for (std.meta.fields(T)) |field| {
                        if (std.mem.eql(u8, field_name, field.name)) {
                            const fval = @field(val.*, field.name);
                            if (comptime field.type == f32) {
                                c.lua_pushnumber(L, fval);
                            } else if (comptime field.type == u32) {
                                c.lua_pushinteger(L, @intCast(fval));
                            }
                            return 1;
                        }
                    }
                    return 0; // unknown field — caller reports error
                }
                return 0;
            }
        }.f,

        .refWriteFn = if (is_tag) null else &struct {
            fn f(engine: *Engine, entity: ecs.Entity, field_name: []const u8, L: ?*c.lua_State) void {
                if (engine.registry.tryGet(T, entity)) |comp| {
                    inline for (std.meta.fields(T)) |field| {
                        if (std.mem.eql(u8, field_name, field.name)) {
                            if (comptime field.type == f32) {
                                @field(comp, field.name) = @floatCast(c.luaL_checknumber(L, 3));
                            } else if (comptime field.type == u32) {
                                @field(comp, field.name) = @intCast(c.luaL_checkinteger(L, 3));
                            }
                            return;
                        }
                    }
                }
            }
        }.f,
    };
}

/// Generic fromLua: reads struct fields from Lua stack starting at `base`.
/// Works for any struct whose fields are all f32 or u32.
fn fromLua(comptime T: type, L: ?*c.lua_State, base: c_int) T {
    const fields = std.meta.fields(T);
    var result: T = .{};
    inline for (fields, 0..) |field, idx| {
        const lua_idx = base + @as(c_int, @intCast(idx));
        if (comptime field.type == f32) {
            @field(result, field.name) = @floatCast(c.luaL_checknumber(L, lua_idx));
        } else if (comptime field.type == u32) {
            @field(result, field.name) = @intCast(c.luaL_checkinteger(L, lua_idx));
        }
    }
    return result;
}

/// Generic toLua: pushes struct fields onto Lua stack. Returns number of values pushed.
fn toLua(comptime T: type, self: T, L: ?*c.lua_State) c_int {
    const fields = std.meta.fields(T);
    inline for (fields) |field| {
        if (comptime field.type == f32) {
            c.lua_pushnumber(L, @field(self, field.name));
        } else if (comptime field.type == u32) {
            c.lua_pushinteger(L, @intCast(@field(self, field.name)));
        }
    }
    return @intCast(fields.len);
}
```

**Important note on imports:** `lua.zig` currently has no dependency on `engine` or `zig-ecs`. Adding these creates a new module dependency. The build.zig must add `"zig-ecs"` and `"engine"` imports to `lua_mod`. This is necessary because the vtable functions close over `Engine` and `ecs.Registry` types.

*Alternative*: If the circular dependency between `lua.zig` and `engine.zig` is problematic (engine imports lua, lua imports engine), the `ComponentOps` struct and `makeComponentOps` can live in a new file `component_ops.zig` that imports both. `lua.zig` stays minimal (just the C import + `nameOf`). This is the **recommended approach** — see implementation notes below.

### 1.3 New file: `component_ops.zig`

To avoid circular imports, extract the vtable into its own module:

```zig
// component_ops.zig — Generated component vtable for Lua bridge dispatch.

const std = @import("std");
const ecs = @import("zig-ecs");
const engine_mod = @import("engine");
const Engine = engine_mod.Engine;
const lua = @import("lua");
const lc = lua.c;

/// Runtime vtable for one component type's Lua bridge operations.
pub const ComponentOps = struct {
    name: []const u8,
    hasFn: *const fn (*ecs.Registry, ecs.Entity) bool,
    lenFn: *const fn (*ecs.Registry) usize,
    dataFn: *const fn (*ecs.Registry) []ecs.Entity,
    addFn: *const fn (*Engine, ecs.Entity, ?*lc.lua_State, c_int) void,
    getFn: *const fn (*Engine, ecs.Entity, ?*lc.lua_State) c_int,
    removeFn: *const fn (*ecs.Registry, ecs.Entity) void,
    refReadFn: ?*const fn (*Engine, ecs.Entity, []const u8, ?*lc.lua_State) c_int,
    refWriteFn: ?*const fn (*Engine, ecs.Entity, []const u8, ?*lc.lua_State) void,
};

// (makeComponentOps, makeOpsForType, fromLua, toLua as specified in 1.2 above)
// The full implementation is identical, just lives here instead of lua.zig.
```

**Build.zig change:** Add a `component_ops_mod` that imports `zig-ecs`, `engine`, `lua`, and `components`. Wire it into `lua_api_mod`'s imports.

### 1.4 `resolveHandle` moves to `Engine`

Currently `resolveHandle` is a private function in `lua_api.zig`. Since vtable-generated `addFn` closures need it, and they receive `*Engine`, it becomes a public method on Engine:

```zig
// engine.zig — new public method
pub const HandleKind = enum { mesh, material };

pub fn resolveHandle(self: *Engine, L: ?*lc.lua_State, idx: c_int, kind: HandleKind) u32 {
    if (lc.lua_type(L, idx) == lc.LUA_TNUMBER) {
        return @intCast(lc.lua_tointeger(L, idx));
    }
    const name = lc.luaL_checklstring(L, idx, null);
    const id = switch (kind) {
        .mesh => self.assets.findMesh(name),
        .material => self.assets.findMaterial(name),
    };
    if (id) |found| return found;
    const label = switch (kind) {
        .mesh => "unknown mesh: %s",
        .material => "unknown material: %s",
    };
    _ = lc.luaL_error(L, label, name);
    unreachable;
}
```

This requires `engine.zig` to import `lc` (it already does via `const lc = lua.c;`).

### 1.5 Rewritten `lua_api.zig`

The entire file is simplified. Here's what changes:

**Removed:**
- `QueryCacheEntry` struct (moved to Phase 2 deletion)
- `max_cached_queries` constant
- `ComponentRef.type_tag` field — replaced by `ops_index: u8` (same concept, but named honestly)
- `makeQueryEntries()` function
- `query_entries` constant
- `findQueryEntry()` function
- `queryHash()` function
- `findCachedQuery()` function
- `findCacheSlot()` function
- `buildQueryTable()` function (rebuilt as standalone, no cache)
- `HandleKind` enum (moved to engine.zig)
- `resolveHandle()` function (moved to engine.zig)
- All 7 `inline for (components.all)` loops in luaAdd, luaGet, luaRemove, luaRef, refIndex, refNewIndex

**Added:**
- `const component_ops = @import("component_ops");`
- `const ops_table = component_ops.makeComponentOps(components.all);`
- `fn findOps(name: []const u8) ?struct { ops: component_ops.ComponentOps, index: u8 }` — single linear search

**Rewritten callbacks:**

```zig
const ops_table = component_ops.makeComponentOps(components.all);

fn findOps(name: []const u8) ?struct { ops: component_ops.ComponentOps, index: u8 } {
    for (ops_table, 0..) |ops, i| {
        if (std.mem.eql(u8, name, ops.name)) return .{ .ops = ops, .index = @intCast(i) };
    }
    return null;
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
```

**`ComponentRef` change:**

```zig
const ComponentRef = extern struct {
    entity_id: u32,
    ops_index: u8,  // was: type_tag
};
```

Semantically identical but the name now says what it is: an index into `ops_table`.

### 1.6 Example component migration

**examples/primitives/components.zig** (after):

```zig
const core = @import("core_components");

pub const Spin = struct {
    speed: f32 = 0,
    pub const lua = .{ .name = "spin" };
};

pub const Player = struct {
    pub const lua = .{ .name = "player" };
};

pub const all = core.withExtra(.{ Spin, Player });
```

No more `const lua = @import("lua");` needed. The `lua` field is just a struct literal — no function call required.

### 1.7 `src/components.zig` migration

Same pattern as example. All component definitions get `.lua = .{ .name = "..." }` instead of `lua.Component(...)` or `lua_name`.

### 1.8 Build.zig changes

Add `component_ops_mod` to the `addExample` function:

```zig
const component_ops_mod = b.createModule(.{
    .root_source_file = b.path("src/component_ops.zig"),
    .target = target,
    .optimize = optimize,
    .link_libc = true,
    .imports = &.{
        .{ .name = "zig-ecs", .module = ecs_mod },
        .{ .name = "engine", .module = engine_mod },
        .{ .name = "lua", .module = lua_mod },
        .{ .name = "components", .module = components_mod },
    },
});

// Add to lua_api_mod imports:
.{ .name = "component_ops", .module = component_ops_mod },
```

---

## Phase 2: Query Cache Elimination

### 2.1 Add `lunatic.each()`

New Lua API function: `lunatic.each("comp1", "comp2", ..., function(entity) ... end)`

The last argument is a callback. All preceding string arguments are component names. For each entity matching all components, calls the callback with the entity ID.

```zig
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

    // Resolve component ops
    var ops: [16]component_ops.ComponentOps = undefined;
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

    // Iterate and call callback
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
                // Propagate error
                return lc.lua_error(L);
            }
        }
    }

    return 0;
}
```

### 2.2 Simplify `lunatic.query()`

Remove all cache machinery. `query()` builds a fresh table every call:

```zig
fn luaQuery(L: ?*lc.lua_State) callconv(.c) c_int {
    const self = getEngine(L);
    const nargs = lc.lua_gettop(L);
    if (nargs == 0) {
        _ = lc.luaL_error(L, "query requires at least one component name");
        return 0;
    }

    var ops: [16]component_ops.ComponentOps = undefined;
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

    // Find smallest set, iterate, filter, build table
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
```

### 2.3 Remove cache fields from `Engine`

**engine.zig changes:**

Remove:
- `query_generation: u64 = 0,`
- `query_cache: [lua_api.max_cached_queries]lua_api.QueryCacheEntry = ...`
- `self.query_generation += 1;` from `run()` (line 266)
- `self.query_generation +%= 1;` from `luaSpawn` and `luaDestroy` in lua_api.zig

**lua_api.zig changes:**

Remove:
- `QueryCacheEntry` struct
- `max_cached_queries` constant
- `findCachedQuery()`
- `findCacheSlot()`
- `buildQueryTable()`
- `queryHash()`

### 2.4 Register `each` in API table

In `registerLuaApi`, add to the `fns` tuple:

```zig
.{ "each", &luaEach },
```

### 2.5 Lua API compatibility

`lunatic.query()` continues to work identically from the Lua side — same arguments, same return value (table of entity IDs). The only behavioral difference: no caching, so calling it twice in one frame builds two tables. This is fine for the entity counts this engine targets.

`lunatic.each()` is additive — new API, no breaking changes.

---

## Phase 3: Renderer Decomposition

### 3.1 New types

```zig
// renderer.zig — new types at top of file

const LightData = struct {
    dir: [4]f32 = .{ 0.4, 0.8, 0.4, 0.0 },
};

const CameraData = struct {
    entity: ecs.Entity,
    pos: Position,
    cam: Camera,
    view: Mat4,
};
```

### 3.2 Extract `gatherLights`

```zig
fn gatherLights(registry: *ecs.Registry) LightData {
    var result = LightData{};
    var light_view = registry.view(.{DirectionalLight}, .{});
    var light_iter = light_view.entityIterator();
    if (light_iter.next()) |light_entity| {
        const dl = light_view.getConst(light_entity);
        const len_sq = dl.dir_x * dl.dir_x + dl.dir_y * dl.dir_y + dl.dir_z * dl.dir_z;
        if (len_sq > 1e-8) {
            result.dir = .{ dl.dir_x, dl.dir_y, dl.dir_z, 0.0 };
        }
    }
    return result;
}
```

### 3.3 Extract `buildDrawList`

Moves entity collection and sorting out of the camera loop. This fixes the latent bug where the draw list was rebuilt per-camera despite being identical.

```zig
fn buildDrawList(self: *Engine) u32 {
    var draw_count: u32 = 0;
    var ecs_view = self.registry.view(.{ Position, Rotation, MeshHandle }, .{});
    var iter = ecs_view.entityIterator();
    while (iter.next()) |entity| {
        if (draw_count >= max_renderables) break;
        const mesh_id: u64 = ecs_view.getConst(MeshHandle, entity).id;
        const mat_id: u64 = if (self.registry.tryGet(MaterialHandle, entity)) |mh| mh.id else 0;
        self.draw_list[draw_count] = .{
            .sort_key = (mesh_id << 32) | mat_id,
            .entity = entity,
        };
        draw_count += 1;
    }

    std.mem.sort(DrawEntry, self.draw_list[0..draw_count], {}, struct {
        fn lessThan(_: void, a: DrawEntry, b: DrawEntry) bool {
            return a.sort_key < b.sort_key;
        }
    }.lessThan);

    return draw_count;
}
```

### 3.4 Extract `submitCameraPass`

The per-camera render pass logic becomes its own function:

```zig
fn submitCameraPass(
    self: *Engine,
    cmd: *c.SDL_GPUCommandBuffer,
    render_pass: *c.SDL_GPURenderPass,
    cam_pos: Position,
    cam: Camera,
    cam_entity: ecs.Entity,
    vp: Mat4,
    light: LightData,
    draw_count: u32,
) void {
    // Set viewport and scissor
    // ... (existing lines 370-388, unchanged)

    // Push scene uniforms
    const scene_uniforms = SceneUniforms{
        .light_dir = light.dir,
        .camera_pos = .{ cam_pos.x, cam_pos.y, cam_pos.z, 0.0 },
        .fog_color = .{ self.fog_color[0], self.fog_color[1], self.fog_color[2], if (self.fog_enabled) 1.0 else 0.0 },
        .fog_params = .{ self.fog_start, self.fog_end, 0.0, 0.0 },
        .ambient = self.ambient_color,
    };
    c.SDL_PushGPUFragmentUniformData(cmd, 0, &scene_uniforms, @sizeOf(SceneUniforms));

    // Draw sorted entities
    var bound_mesh: ?u32 = null;
    var bound_mat: ?u32 = null;

    for (self.draw_list[0..draw_count]) |entry| {
        // ... (existing draw loop body, lines 444-515, unchanged)
    }
}
```

### 3.5 Simplified `renderSystem`

```zig
pub fn renderSystem(self: *Engine, device: *c.SDL_GPUDevice, dt: f32) void {
    _ = dt;
    const cmd = c.SDL_AcquireGPUCommandBuffer(device) orelse return;

    // Acquire swapchain (unchanged, lines 263-273)
    // Recreate render targets if needed (unchanged, lines 275-289)

    const light = gatherLights(&self.registry);
    const draw_count = buildDrawList(self);

    // Camera loop (same structure, but calls submitCameraPass)
    var cam_view = self.registry.view(.{ Position, Camera }, .{});
    var cam_iter = cam_view.entityIterator();
    var first_camera = true;
    while (cam_iter.next()) |cam_entity| {
        const cam_pos = cam_view.getConst(Position, cam_entity);
        const cam = cam_view.getConst(Camera, cam_entity);

        // Color/depth target setup (unchanged, lines 320-363)
        // ...

        const render_pass = c.SDL_BeginGPURenderPass(cmd, &color_target, 1, &depth_target) orelse continue;
        c.SDL_BindGPUGraphicsPipeline(render_pass, self.pipeline);

        // View/projection matrix computation (unchanged, lines 390-406)
        const vp = Mat4.mul(proj, view);

        submitCameraPass(self, cmd, render_pass, cam_pos, cam, cam_entity, vp, light, draw_count);
        c.SDL_EndGPURenderPass(render_pass);

        first_camera = false;
    }

    _ = c.SDL_SubmitGPUCommandBuffer(cmd);
}
```

The `renderSystem` function goes from ~264 lines to ~60 lines. Each extracted function is focused and independently testable.

---

## Implementation Order

### Step 1: Create `component_ops.zig`
- New file with `ComponentOps` struct, `makeComponentOps`, `fromLua`, `toLua`
- Add to build.zig as new module

### Step 2: Migrate component definitions
- Update `core_components.zig`: replace `lua.Component(...)` with `.lua = .{ .name = "..." }`
- Update `src/components.zig`: same migration
- Update `examples/primitives/components.zig`: same migration
- Remove `lua.Component()`, `lua.hasBindings()`, `lua.isTag()` from `lua.zig`
- Simplify `lua.nameOf()` to read `T.lua.name`

### Step 3: Move `resolveHandle` to Engine
- Add `pub const HandleKind` and `pub fn resolveHandle` to `engine.zig`
- Remove from `lua_api.zig`
- Engine already imports `lc`

### Step 4: Rewrite `lua_api.zig` dispatch
- Import `component_ops`
- Create `ops_table` and `findOps`
- Rewrite `luaAdd`, `luaGet`, `luaRemove`, `luaRef`, `refIndex`, `refNewIndex`
- Rename `ComponentRef.type_tag` to `ops_index`
- Remove old query infrastructure (`makeQueryEntries`, `query_entries`, `findQueryEntry`, `queryHash`)

### Step 5: Eliminate query cache
- Add `luaEach` function
- Rewrite `luaQuery` (no cache)
- Remove `QueryCacheEntry`, `max_cached_queries`, cache helpers
- Remove `query_generation` and `query_cache` from `Engine`
- Remove generation increment sites
- Register `"each"` in API table

### Step 6: Decompose renderer
- Add `LightData` struct
- Extract `gatherLights()`
- Extract `buildDrawList()` (moves out of camera loop)
- Extract `submitCameraPass()`
- Simplify `renderSystem()`

### Step 7: Verify
- `zig build test` — all existing tests pass
- Build and run `primitives` example
- Build and run `pbr_test` example
- Verify Lua API behaves identically: `spawn`, `add`, `get`, `remove`, `ref`, `query`, `system`

---

## Acceptance Criteria

- [ ] All existing tests pass (`zig build test`)
- [ ] Both examples build and run (`zig build run-primitives`, `zig build run-pbr_test`)
- [ ] No `inline for (components.all)` loops remain in `lua_api.zig`
- [ ] No `comptime T == MeshHandle` or `comptime T == MaterialHandle` special-cases remain
- [ ] `query_generation` and `query_cache` fields are gone from `Engine`
- [ ] `lunatic.each()` works from Lua
- [ ] `lunatic.query()` still works (no cache, builds fresh table)
- [ ] `renderSystem()` is under 80 lines
- [ ] Adding a new data component requires only: define struct with `.lua`, add to `.all` tuple
- [ ] Adding a new asset handle component requires only: define struct with `.lua = .{ .name = "...", .resolve = .xxx }`, add to `.all` tuple, add variant to `HandleKind`

---

## Files Changed

| File | Action | Phase |
|------|--------|-------|
| `src/component_ops.zig` | **New** — vtable struct + generator | 1 |
| `src/lua.zig` | Simplify — remove `Component()`, `hasBindings()`, `isTag()` | 1 |
| `src/core_components.zig` | Migrate — `.lua` metadata format | 1 |
| `src/components.zig` | Migrate — `.lua` metadata format | 1 |
| `examples/primitives/components.zig` | Migrate — `.lua` metadata format | 1 |
| `src/engine.zig` | Add `resolveHandle`; remove query cache fields | 1+2 |
| `src/lua_api.zig` | Major rewrite — vtable dispatch, no cache | 1+2 |
| `src/renderer.zig` | Decompose `renderSystem` into 3 functions | 3 |
| `build.zig` | Add `component_ops_mod` | 1 |

---

## Risks and Mitigations

**Risk:** Circular import between `component_ops.zig` and `engine.zig`.
**Mitigation:** `component_ops.zig` imports Engine as a type but never calls `init`/`deinit`. The build system handles the dependency via module imports, not file-level `@import`. Zig's lazy compilation means this works as long as there's no actual circular *call* at comptime.

**Risk:** vtable function pointers are slightly slower than comptime dispatch.
**Mitigation:** One indirect call per Lua C callback invocation. The Lua C API overhead (stack manipulation, type checks) dwarfs a single indirect call. Unmeasurable in practice.

**Risk:** `query()` without cache is slower for hot paths with many entities.
**Mitigation:** `each()` provides a zero-allocation alternative. For typical entity counts (<10k), table construction is sub-microsecond. If profiling shows a problem, a simpler per-frame cache can be re-added later — but it should live entirely in `lua_api.zig`, not split across modules.

**Risk:** `buildDrawList()` extracted from camera loop changes rendering behavior for multi-camera setups.
**Mitigation:** The draw list was already the same for all cameras (same entities, same sort keys). Moving it out of the loop is a pure optimization, not a behavioral change. The only difference: entities spawned between camera passes within the same frame won't appear until next frame. This is already the case in practice since Lua systems run before rendering.
