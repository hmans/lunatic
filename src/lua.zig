// lua.zig — shared Lua C import and binding utilities.

const std = @import("std");

pub const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lualib.h");
    @cInclude("lauxlib.h");
});

/// Get the Lua name for any component type (checks .Lua.lua_name then .lua_name).
pub fn nameOf(comptime T: type) []const u8 {
    if (@hasDecl(T, "Lua")) return T.Lua.lua_name;
    if (@hasDecl(T, "lua_name")) return T.lua_name;
    @compileError("component type has no lua_name");
}

/// Does this component type have auto-generated Lua bindings?
pub fn hasBindings(comptime T: type) bool {
    return @hasDecl(T, "Lua");
}

/// Is this a tag component (zero-sized)?
pub fn isTag(comptime T: type) bool {
    return @sizeOf(T) == 0;
}

/// Auto-generates fromLua/toLua for any struct of f32/u32 fields.
/// Returns a type with `lua_name`, `fromLua(L, base) -> T`, `toLua(val, L) -> c_int`.
pub fn Component(comptime name: []const u8, comptime Self: type) type {
    const fields = std.meta.fields(Self);

    return struct {
        pub const lua_name = name;

        pub fn fromLua(L: ?*c.lua_State, base: c_int) Self {
            var result: Self = .{};
            inline for (fields, 0..) |field, i| {
                const idx = base + @as(c_int, @intCast(i));
                if (comptime field.type == f32) {
                    @field(result, field.name) = @floatCast(c.luaL_checknumber(L, idx));
                } else if (comptime field.type == u32) {
                    @field(result, field.name) = @intCast(c.luaL_checkinteger(L, idx));
                }
            }
            return result;
        }

        pub fn toLua(self: Self, L: ?*c.lua_State) c_int {
            inline for (fields) |field| {
                if (comptime field.type == f32) {
                    c.lua_pushnumber(L, @field(self, field.name));
                } else if (comptime field.type == u32) {
                    c.lua_pushinteger(L, @intCast(@field(self, field.name)));
                }
            }
            return @intCast(fields.len);
        }
    };
}
