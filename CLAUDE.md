# Lunatic Engine

A 3D game engine: Zig core + SDL3 GPU + LuaJIT scripting + zig-ecs.

## Goals

- **Performance**: engine core in Zig, fully ECS-based architecture
- **Hackable**: Optional Lua scripting for hot-reloadable system implementations; game projects fork and modify the engine repo for maximum flexibility
- **Agent friendly**: simple architecture and Lua API for easy integration with AI agents (e.g. via natural language descriptions of game logic)

## Details

- Components are defined in Zig, with optional metadata for automatic Lua bindings

## Conventions

- Use Conventional Commit formatting for commit messages
- `lc` = Lua C namespace, `c` = SDL C namespace (separate `@cImport`s to avoid type conflicts)
- Query results are cached per frame via FNV-1a hash of component names
