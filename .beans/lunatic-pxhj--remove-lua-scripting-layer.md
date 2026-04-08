---
# lunatic-pxhj
title: Remove Lua scripting layer
status: completed
type: task
priority: normal
created_at: 2026-04-08T15:59:12Z
updated_at: 2026-04-08T16:38:49Z
---

Strip all Lua/LuaJIT from the engine. Go pure Zig. Removes lua_api.zig, lua.zig, component Lua metadata, LuaJIT dependency, Lua bridge in component_ops.zig, and all related build infrastructure. Game entry point becomes main.zig only.

## Summary of Changes

Removed all Lua/LuaJIT scripting infrastructure from the engine (-2,931 lines, +127 lines):

**Deleted files:**
- `engine/src/lua.zig` — Lua C import wrapper
- `engine/src/lua_api.zig` — 1,226 lines of Lua C callbacks and API registration
- `engine/src/component_ops.zig` — Component vtable for Lua bridge dispatch
- `engine/vendor/lua_error_helper.c` — Lua/Zig interop helper
- `game/main.lua`, `examples/main.lua`, `examples/scenes/*.lua` — All Lua scripts

**Modified files:**
- `engine/src/engine.zig` — Removed Lua state, loadScript(), Lua system callbacks, resolveHandle(), system registration
- `engine/src/debug_server.zig` — Removed /lua endpoint and Lua→JSON helpers
- `engine/src/core_components.zig` — Removed `pub const lua` metadata from all 15 components
- `examples/components.zig` — Removed lua metadata from Spin and Player
- `build.zig` — Removed LuaJIT dependency, lua/lua_api/component_ops modules
- `engine/src/tests.zig` — Rewritten as pure Zig integration tests (was Lua-based)
- `mcp/server.mjs` — Removed eval_lua tool
- `README.md`, `CLAUDE.md`, `AGENTS.md` — Updated to reflect pure-Zig architecture
- `game/main.zig`, `examples/main.zig` — Removed loadScript() calls



## Port Lua examples to Zig

- [x] Add physics helper methods on Engine (addPhysicsBox, addPhysicsSphere, optimizePhysics)
- [x] Port physics_rain scene to Zig
- [x] Port lighting_gallery scene to Zig
- [x] Port material_showcase scene to Zig
- [x] Port scene manager + debug UI to Zig examples/main.zig
- [x] Build and verify
