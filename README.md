# Lunatic Engine

A 3D game engine: Zig core + SDL3 GPU + LuaJIT scripting + zig-ecs.

## Architecture

- **Zig** owns the ECS registry, GPU rendering, and the game loop
- **Lua** owns game logic: spawns entities, sets components, registers systems
- **Systems** can be Zig (performance-critical) or Lua (hot-reloadable)
- **Shaders** are authored in GLSL, cross-compiled to SPIR-V and MSL at build time

## Dependencies

Install via [Homebrew](https://brew.sh/):

```
brew install zig sdl3 luajit shaderc spirv-cross
```

| Dependency | Purpose |
|---|---|
| [Zig](https://ziglang.org/) 0.15+ | Compiler and build system |
| [SDL3](https://libsdl.org/) | Windowing, input, GPU abstraction |
| [LuaJIT](https://luajit.org/) | Scripting runtime |
| [shaderc](https://github.com/google/shaderc) | GLSL to SPIR-V compilation |
| [SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross) | SPIR-V to MSL cross-compilation |

[zig-ecs](https://github.com/prime31/zig-ecs) is fetched automatically by the build system.

## Build & Run

```
zig build run
```

## Tests

```
zig build test
```

## Project Structure

```
src/
  engine.zig      Engine core (importable as a library)
  main.zig        Standalone entry point
  components.zig  ECS component definitions
  lua.zig         Lua binding utilities and comptime macros
  math3d.zig      Vec3, Mat4 (column-major)
  tests.zig       Headless integration tests

shaders/
  default.vert    Vertex shader (GLSL 450)
  default.frag    Fragment shader (GLSL 450)

game/
  main.lua        Game script
```

## Lua API (`lunatic.*`)

- `spawn()`, `destroy(e)` -- entity lifecycle
- `add(e, name, ...)`, `get(e, name)`, `remove(e, name)` -- component access
- `ref(e, name)` -- returns a proxy with direct field access (`pos.x = 5`)
- `query(name, ...)` -- returns cached table of matching entity IDs
- `system(name, fn)` -- register a per-frame Lua system
- `set_camera`, `set_clear_color`, `set_fog`, `set_light`, `set_ambient`, `key_down`

## Using as a Library

The engine can be imported as a Zig module:

```zig
const Engine = @import("lunatic").Engine;

pub fn main() !void {
    var engine: Engine = undefined;
    try engine.init(.{
        .title = "My Game",
        .width = 1280,
        .height = 720,
    });
    defer engine.deinit();

    try engine.loadScript("game/main.lua");
    try engine.run();
}
```
