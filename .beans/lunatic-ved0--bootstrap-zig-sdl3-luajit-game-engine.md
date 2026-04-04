---
# lunatic-ved0
title: Bootstrap Zig + SDL3 + LuaJIT game engine
status: completed
type: task
priority: normal
created_at: 2026-04-03T16:17:29Z
updated_at: 2026-04-03T16:20:34Z
---

Set up project structure with build.zig, SDL3 window, LuaJIT integration, and a basic game loop that calls into Lua for init/update/draw.

## Summary of Changes

Bootstrapped the gammo engine with:
- `build.zig` — Zig 0.15 build config linking SDL3 and LuaJIT
- `src/main.zig` — engine core with SDL3 window, game loop, and Lua API (clear, rect, key_down)
- `game/main.lua` — demo game with a bouncing square and arrow key input

Worked through several Zig 0.15 API changes (root_module) and C macro translation issues (lua_tostring, luaL_checkstring, SDL bool types).
