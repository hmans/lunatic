# Lunatic Engine

A highly experimental toy 3D game engine written in Zig.

- Written in Zig
- ECS-first architecture (using `zig-ecs`)
- Systems can be authored in Zig or Lua (hot-reloadable)
- Builds on top of SDL3 for windowing, input, rendering, and more

## Dependencies

Install via [Homebrew](https://brew.sh/):

```
brew install zig sdl3 luajit shaderc spirv-cross
```

## Build & Run

```
zig build run
```

## Tests

```
zig build test
```

