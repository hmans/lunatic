# Lunatic Engine

A highly experimental toy 3D game engine designed for agentic engineering.

## Features

- Core engine written in Zig
- Fully ECS-driven architecture
- Games can be authored in Zig, hot-reloadable Lua, or a mix of both
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

