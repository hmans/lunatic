# Lunatic Engine

A 3D game engine: Zig core + SDL3 GPU + LuaJIT scripting + zig-ecs.

## Goals

- **Performance**: engine core in Zig, fully ECS-based architecture
- **Hackable**: Optional Lua scripting for hot-reloadable system implementations; game projects fork and modify the engine repo for maximum flexibility
- **Agent friendly**: simple architecture and Lua API for easy integration with AI agents (e.g. via natural language descriptions of game logic)

## Details

- Components are defined in Zig, with optional metadata for automatic Lua bindings
- Engine code is split by responsibility: `engine.zig` (lifecycle, registries), `renderer.zig` (GPU pipeline, render system), `lua_api.zig` (Lua bindings). Both renderer and lua_api import the Engine type from engine.zig.

## Conventions

- Use Conventional Commit formatting for commit messages
- `lc` = Lua C namespace (from `lua.zig`), `c` = SDL C namespace (from `engine.zig`). Both are `pub const` exports — other files must import these rather than doing their own `@cImport`.
- Query results are cached per frame via FNV-1a hash of component names
- Any new APIs must be made available to Zig first, and then (optionally, where it makes sense) to Lua.

- Mesh winding order is CCW (counter-clockwise) when viewed from outside. Pipeline uses `CULLMODE_BACK` + `FRONTFACE_COUNTER_CLOCKWISE`. New geometry generators should verify winding with the cross-product dot normal test.

## Gotchas

- **Shared `@cImport`**: Each `@cImport` in Zig creates distinct opaque types. If two files each `@cImport("SDL3/SDL.h")`, their `SDL_GPUDevice` types are incompatible. Always import `c` from `engine.zig` and `lc` from `lua.zig`.
- **Shader cache staleness**: The zig build cache doesn't always invalidate spirv-cross MSL output when GLSL sources change. Run `rm -rf .zig-cache` after modifying shaders if you see stale behavior.
- **MSAA + multiple render passes**: Use `STOREOP_RESOLVE_AND_STORE` (not `STOREOP_RESOLVE`) when subsequent render passes need to load from the MSAA color texture. Plain RESOLVE discards MSAA contents.
