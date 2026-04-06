# Lunatic Engine

A highly experimental toy 3D game engine designed for agentic engineering.

## Features

- Core engine written in Zig
- Fully ECS-driven architecture
- Games can be authored in Zig, hot-reloadable Lua, or a mix of both
- Builds on top of SDL3 for windowing, input, rendering, and more
- 3D physics simulation powered by [Jolt Physics](https://github.com/jrouwe/JoltPhysics)
- Built-in HTTP API and MCP server for agentic control and debugging

## This is an Experiment

This project exists because I want to test if the old truism of "don't build your own game engine" still holds true in 2026. It is not meant to compete with engines like Unity, Unreal, or Godot; there are no plans to turn this into any kind of serious project. Instead, consider it **a sandbox for exploring game and game engine development in the age of agentic engineering**.

If there is a hypothesis that I want to test, it's that instead of using a monolithic general-purpose engine, or even just pulling in an engine as a library, you can just grab a copy of this repository and hack on it, ideally with the help of an agent. You and your clanker will not only be able to write game code, but also have full access to and control over the engine itself; no waiting for another company to implement your feature request, no submitting a PR to another project and hoping it gets merged, no dealing with breaking changes in engine updates.

As you can imagine, this project itself has been entirely clanked. To even get it to the state it's currently in was only possible because I already have a bit of experience with game engine development, but also because I've instructed the agent to research thoroughly the state of the art of specific features I wanted to add. In other words: this entire project rests on the shoulders of giants, which is also why the only possible license for this project is the Unlicense, putting all of it straight into the public domain. This means you can literally do anything you want with the code, no attribution required, no strings attached.

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

