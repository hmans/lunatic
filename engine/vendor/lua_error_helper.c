// Tiny C helper to safely call lua_error from Zig.
// lua_error does a longjmp which is undefined behavior through Zig stack frames.
// By calling it from C, the longjmp only unwinds C frames which is safe.
#include <lua.h>
#include <lauxlib.h>

int lunatic_lua_error(lua_State *L) {
    return lua_error(L);
}

int lunatic_luaL_error(lua_State *L, const char *msg) {
    return luaL_error(L, "%s", msg);
}
