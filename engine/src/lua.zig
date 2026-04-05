// lua.zig — shared Lua C import and binding utilities.

pub const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lualib.h");
    @cInclude("lauxlib.h");
});

/// Get the Lua name for any component type.
pub fn nameOf(comptime T: type) []const u8 {
    return T.lua.name;
}
