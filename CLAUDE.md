# Lunatic Engine

A 3D game engine: Zig core + SDL3 GPU + LuaJIT scripting + zig-ecs.

## Architecture

- **Zig** owns the ECS registry, GPU rendering, and the game loop
- **Lua** owns game logic: spawns entities, sets components, registers systems
- **Systems** can be Zig (performance-critical) or Lua (hot-reloadable)
- Rendering is a Zig system querying `Position + Rotation + MeshHandle`

## Key Files

- `src/main.zig` — engine core: SDL3 init, GPU pipeline, game loop, Lua API, render system
- `src/components.zig` — ECS component definitions. `components.all` is the single source of truth
- `src/lua.zig` — shared Lua C import, `lua.Component()` comptime mixin, `lua.nameOf()`, `lua.isTag()`
- `src/math3d.zig` — Vec3, Mat4 (column-major, perspective, lookAt, rotation, translation)
- `game/main.lua` — the game script (setup + system registration)
- `build.zig` — links SDL3, LuaJIT, zig-ecs

## Adding a Component

1. Define the struct in `components.zig` with `pub const Lua = lua.Component("name", @This());`
2. Add it to `components.all`
3. Done — `lunatic.add/get/remove/ref/query` all work automatically via comptime dispatch

Tag components (zero-sized structs) work the same way. `lunatic.get()` returns `true/false` for tags.

`MeshHandle` is the one special case — needs mesh registry lookup in `luaAdd`.

## Lua API (`lunatic.*`)

- `spawn()`, `destroy(e)` — entity lifecycle
- `add(e, name, ...)`, `get(e, name)`, `remove(e, name)` — component access
- `ref(e, name)` — returns a proxy with `__index`/`__newindex` for direct field access
- `query(name, ...)` — returns cached table of entity IDs matching all components
- `system(name, fn)` — register a Lua function as a per-frame system
- `set_camera`, `set_clear_color`, `set_fog`, `set_light`, `set_ambient`, `key_down`

## Build & Run

```
zig build run
```

Requires: Zig 0.15+, SDL3, LuaJIT (all via Homebrew on macOS).

## Conventions

- Shaders are MSL (Metal) embedded as string literals — macOS only for now
- `lc` = Lua C namespace, `c` = SDL C namespace (separate `@cImport`s to avoid type conflicts)
- Query results are cached per frame via FNV-1a hash of component names
