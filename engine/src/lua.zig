// lua.zig — shared LuaJIT C import.
//
// Separate module to avoid merging LuaJIT types into engine.zig's @cImport
// block (which would create type conflicts with SDL — see "Shared @cImport" gotcha).

pub const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lualib.h");
    @cInclude("lauxlib.h");
});
