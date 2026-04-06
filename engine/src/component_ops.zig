// component_ops.zig — Generated component vtable for Lua bridge dispatch.
//
// Each component type in `components.all` gets a `ComponentOps` entry with
// function pointers for add/get/remove/query/ref operations. This replaces
// the repeated `inline for (components.all)` dispatch loops in lua_api.zig.
//
// With flecs, component access goes through the world pointer (stored on Engine)
// rather than a separate Registry object. Entity IDs are u64 (flecs entity_t).

const std = @import("std");
const ecs = @import("zflecs");
const engine_mod = @import("engine");
const Engine = engine_mod.Engine;
const lua = @import("lua");
const lc = lua.c;

/// Runtime vtable for one component type's Lua bridge operations.
pub const ComponentOps = struct {
    name: []const u8,
    idFn: *const fn () ecs.id_t,

    // ECS query operations
    hasFn: *const fn (*Engine, ecs.entity_t) bool,
    countFn: *const fn (*Engine) usize,

    // Lua bridge operations
    addFn: *const fn (*Engine, ecs.entity_t, ?*lc.lua_State, c_int) void,
    getFn: *const fn (*Engine, ecs.entity_t, ?*lc.lua_State) c_int,
    removeFn: *const fn (*Engine, ecs.entity_t) void,

    // Component ref field access (null for tag components)
    refReadFn: ?*const fn (*Engine, ecs.entity_t, []const u8, ?*lc.lua_State) c_int,
    refWriteFn: ?*const fn (*Engine, ecs.entity_t, []const u8, ?*lc.lua_State) void,
};

/// Generate a ComponentOps vtable entry for each type in the tuple.
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
        .idFn = &struct {
            fn f() ecs.id_t {
                return ecs.id(T);
            }
        }.f,

        .hasFn = &struct {
            fn f(engine: *Engine, entity: ecs.entity_t) bool {
                return ecs.has_id(engine.world, entity, ecs.id(T));
            }
        }.f,
        .countFn = &struct {
            fn f(engine: *Engine) usize {
                return @intCast(ecs.count_id(engine.world, ecs.id(T)));
            }
        }.f,

        .addFn = &struct {
            fn f(engine: *Engine, entity: ecs.entity_t, L: ?*lc.lua_State, base: c_int) void {
                if (comptime is_tag) {
                    ecs.add(engine.world, entity, T);
                } else if (comptime has_resolve) {
                    const id = engine.resolveHandle(L, base, T.lua.resolve);
                    _ = ecs.set(engine.world, entity, T, T{ .id = id });
                } else {
                    _ = ecs.set(engine.world, entity, T, fromLua(T, L, base));
                }
            }
        }.f,

        .getFn = &struct {
            fn f(engine: *Engine, entity: ecs.entity_t, L: ?*lc.lua_State) c_int {
                if (comptime is_tag) {
                    lc.lua_pushboolean(L, if (ecs.has_id(engine.world, entity, ecs.id(T))) 1 else 0);
                    return 1;
                } else {
                    if (ecs.get(engine.world, entity, T)) |val| {
                        return toLua(T, val.*, L);
                    }
                    return 0;
                }
            }
        }.f,

        .removeFn = &struct {
            fn f(engine: *Engine, entity: ecs.entity_t) void {
                ecs.remove(engine.world, entity, T);
            }
        }.f,

        .refReadFn = if (is_tag) null else &struct {
            fn f(engine: *Engine, entity: ecs.entity_t, field_name: []const u8, L: ?*lc.lua_State) c_int {
                if (ecs.get(engine.world, entity, T)) |val| {
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
                    return 0;
                }
                return 0;
            }
        }.f,

        .refWriteFn = if (is_tag) null else &struct {
            fn f(engine: *Engine, entity: ecs.entity_t, field_name: []const u8, L: ?*lc.lua_State) void {
                if (ecs.get_mut(engine.world, entity, T)) |comp| {
                    inline for (std.meta.fields(T)) |field| {
                        if (std.mem.eql(u8, field_name, field.name)) {
                            if (comptime field.type == f32) {
                                @field(comp, field.name) = @floatCast(lc.luaL_checknumber(L, 3));
                            } else if (comptime field.type == u32) {
                                @field(comp, field.name) = @intCast(lc.luaL_checkinteger(L, 3));
                            }
                            return;
                        }
                    }
                }
            }
        }.f,
    };
}

/// Read struct fields from Lua stack starting at `base`.
fn fromLua(comptime T: type, L: ?*lc.lua_State, base: c_int) T {
    const fields = std.meta.fields(T);
    var result: T = .{};
    inline for (fields, 0..) |field, idx| {
        const lua_idx = base + @as(c_int, @intCast(idx));
        if (comptime field.type == f32) {
            const default: f64 = if (field.default_value_ptr) |ptr|
                @as(*const f32, @ptrCast(@alignCast(ptr))).*
            else
                0;
            @field(result, field.name) = @floatCast(lc.luaL_optnumber(L, lua_idx, default));
        } else if (comptime field.type == u32) {
            const default: lc.lua_Integer = if (field.default_value_ptr) |ptr|
                @as(*const u32, @ptrCast(@alignCast(ptr))).*
            else
                0;
            @field(result, field.name) = @intCast(lc.luaL_optinteger(L, lua_idx, default));
        }
    }
    return result;
}

/// Push struct fields onto Lua stack. Returns number of values pushed.
fn toLua(comptime T: type, self: T, L: ?*lc.lua_State) c_int {
    const fields = std.meta.fields(T);
    inline for (fields) |field| {
        if (comptime field.type == f32) {
            lc.lua_pushnumber(L, @field(self, field.name));
        } else if (comptime field.type == u32) {
            lc.lua_pushinteger(L, @intCast(@field(self, field.name)));
        }
    }
    return @intCast(fields.len);
}
