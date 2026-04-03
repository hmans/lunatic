const std = @import("std");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("lua.h");
    @cInclude("lualib.h");
    @cInclude("lauxlib.h");
});

// ============================================================
// Lua-callable engine API
// ============================================================

/// gammo.clear(r, g, b) — fill the screen with a color
fn luaClear(L: ?*c.lua_State) callconv(.c) c_int {
    const r: u8 = @intFromFloat(c.luaL_checknumber(L, 1));
    const g: u8 = @intFromFloat(c.luaL_checknumber(L, 2));
    const b: u8 = @intFromFloat(c.luaL_checknumber(L, 3));

    if (renderer) |ren| {
        _ = c.SDL_SetRenderDrawColor(ren, r, g, b, 255);
        _ = c.SDL_RenderClear(ren);
    }
    return 0;
}

/// gammo.rect(x, y, w, h, r, g, b) — draw a filled rectangle
fn luaRect(L: ?*c.lua_State) callconv(.c) c_int {
    const x: f32 = @floatCast(c.luaL_checknumber(L, 1));
    const y: f32 = @floatCast(c.luaL_checknumber(L, 2));
    const w: f32 = @floatCast(c.luaL_checknumber(L, 3));
    const h: f32 = @floatCast(c.luaL_checknumber(L, 4));
    const r: u8 = @intFromFloat(c.luaL_checknumber(L, 5));
    const g: u8 = @intFromFloat(c.luaL_checknumber(L, 6));
    const b: u8 = @intFromFloat(c.luaL_checknumber(L, 7));

    if (renderer) |ren| {
        _ = c.SDL_SetRenderDrawColor(ren, r, g, b, 255);
        const rect = c.SDL_FRect{ .x = x, .y = y, .w = w, .h = h };
        _ = c.SDL_RenderFillRect(ren, &rect);
    }
    return 0;
}

/// gammo.key_down(name) — returns true if the named key is currently pressed
fn luaKeyDown(L: ?*c.lua_State) callconv(.c) c_int {
    const name = c.luaL_checklstring(L, 1, null);
    const scancode = c.SDL_GetScancodeFromName(name);
    const state = c.SDL_GetKeyboardState(null);
    c.lua_pushboolean(L, if (state[scancode]) 1 else 0);
    return 1;
}

// Table of engine functions exposed to Lua
const gammo_lib = [_]c.luaL_Reg{
    .{ .name = "clear", .func = luaClear },
    .{ .name = "rect", .func = luaRect },
    .{ .name = "key_down", .func = luaKeyDown },
    .{ .name = null, .func = null }, // sentinel
};

// ============================================================
// Globals (accessed by Lua callbacks)
// ============================================================

var renderer: ?*c.SDL_Renderer = null;

// ============================================================
// Main
// ============================================================

pub fn main() !void {
    // ----- SDL3 init -----
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.debug.print("SDL_Init failed: {s}\n", .{c.SDL_GetError()});
        return error.SDLInitFailed;
    }
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow("gammo", 800, 600, 0);
    if (window == null) {
        std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
        return error.SDLWindowFailed;
    }
    defer c.SDL_DestroyWindow(window);

    renderer = c.SDL_CreateRenderer(window, null);
    if (renderer == null) {
        std.debug.print("SDL_CreateRenderer failed: {s}\n", .{c.SDL_GetError()});
        return error.SDLRendererFailed;
    }
    defer c.SDL_DestroyRenderer(renderer);

    // ----- Lua init -----
    const L = c.luaL_newstate() orelse return error.LuaInitFailed;
    defer c.lua_close(L);
    c.luaL_openlibs(L);

    // Register the "gammo" module table
    c.luaL_register(L, "gammo", &gammo_lib);
    c.lua_pop(L, 1);

    // Load the game script
    if (c.luaL_loadfile(L, "game/main.lua") != 0 or c.lua_pcall(L, 0, 0, 0) != 0) {
        const err = c.lua_tolstring(L, -1, null);
        std.debug.print("Lua error: {s}\n", .{err});
        return error.LuaLoadFailed;
    }

    // Call game.init()
    callLua(L, "init", 0);

    // ----- Game loop -----
    var running = true;
    var last_time = c.SDL_GetPerformanceCounter();
    const freq: f64 = @floatFromInt(c.SDL_GetPerformanceFrequency());

    // Delta time smoothing (EMA)
    const dt_smoothing = 0.1;
    const dt_max = 0.25; // clamp to avoid spiral-of-death
    var smooth_dt: f64 = 1.0 / 60.0;

    while (running) {
        // Timing
        const now = c.SDL_GetPerformanceCounter();
        const raw_dt = @min(@as(f64, @floatFromInt(now - last_time)) / freq, dt_max);
        last_time = now;
        smooth_dt += dt_smoothing * (raw_dt - smooth_dt);
        const dt = smooth_dt;

        // Events
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            if (event.type == c.SDL_EVENT_QUIT) {
                running = false;
            }
            if (event.type == c.SDL_EVENT_KEY_DOWN and event.key.scancode == c.SDL_SCANCODE_ESCAPE) {
                running = false;
            }
        }

        // Update — push dt as argument
        _ = c.lua_getglobal(L, "update");
        c.lua_pushnumber(L, dt);
        if (c.lua_pcall(L, 1, 0, 0) != 0) {
            const err = c.lua_tolstring(L, -1, null);
            std.debug.print("Lua update error: {s}\n", .{err});
            c.lua_pop(L, 1);
        }

        // Draw
        callLua(L, "draw", 0);

        // Present
        _ = c.SDL_RenderPresent(renderer);
    }
}

/// Call a global Lua function with no arguments
fn callLua(L: *c.lua_State, name: [*:0]const u8, nargs: c_int) void {
    _ = c.lua_getglobal(L, name);
    if (c.lua_pcall(L, nargs, 0, 0) != 0) {
        const err = c.lua_tolstring(L, -1, null);
        std.debug.print("Lua {s}() error: {s}\n", .{ name, err });
        c.lua_pop(L, 1);
    }
}
