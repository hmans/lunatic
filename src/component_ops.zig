// component_ops.zig — Generated component vtable for Lua bridge dispatch.
//
// Each component type in `components.all` gets a `ComponentOps` entry with
// function pointers for add/get/remove/query/ref operations. This replaces
// the repeated `inline for (components.all)` dispatch loops in lua_api.zig.

const std = @import("std");
const ecs = @import("zig-ecs");
const engine_mod = @import("engine");
const Engine = engine_mod.Engine;
const lua = @import("lua");
const lc = lua.c;

/// Runtime vtable for one component type's Lua bridge operations.
pub const ComponentOps = struct {
    name: []const u8,

    // ECS query operations
    hasFn: *const fn (*ecs.Registry, ecs.Entity) bool,
    lenFn: *const fn (*ecs.Registry) usize,
    dataFn: *const fn (*ecs.Registry) []ecs.Entity,

    // Lua bridge operations
    addFn: *const fn (*Engine, ecs.Entity, ?*lc.lua_State, c_int) void,
    getFn: *const fn (*Engine, ecs.Entity, ?*lc.lua_State) c_int,
    removeFn: *const fn (*ecs.Registry, ecs.Entity) void,

    // Component ref field access (null for tag components)
    refReadFn: ?*const fn (*Engine, ecs.Entity, []const u8, ?*lc.lua_State) c_int,
    refWriteFn: ?*const fn (*Engine, ecs.Entity, []const u8, ?*lc.lua_State) void,
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
            fn f(engine: *Engine, entity: ecs.Entity, L: ?*lc.lua_State, base: c_int) void {
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
            fn f(engine: *Engine, entity: ecs.Entity, L: ?*lc.lua_State) c_int {
                if (comptime is_tag) {
                    lc.lua_pushboolean(L, if (engine.registry.has(T, entity)) 1 else 0);
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
            fn f(engine: *Engine, entity: ecs.Entity, field_name: []const u8, L: ?*lc.lua_State) c_int {
                if (engine.registry.tryGet(T, entity)) |val| {
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
            fn f(engine: *Engine, entity: ecs.Entity, field_name: []const u8, L: ?*lc.lua_State) void {
                if (engine.registry.tryGet(T, entity)) |comp| {
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
            @field(result, field.name) = @floatCast(lc.luaL_checknumber(L, lua_idx));
        } else if (comptime field.type == u32) {
            @field(result, field.name) = @intCast(lc.luaL_checkinteger(L, lua_idx));
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
