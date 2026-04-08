// lua_error_helper.c — C shim for lua_error/luaL_error.
//
// lua_error() does longjmp, which is undefined behavior when unwinding through
// Zig stack frames. These wrappers ensure longjmp only unwinds C frames.

#include <lua.h>
#include <lauxlib.h>

int lunatic_lua_error(lua_State *L) {
    return lua_error(L);
}

int lunatic_luaL_error(lua_State *L, const char *msg) {
    return luaL_error(L, "%s", msg);
}
