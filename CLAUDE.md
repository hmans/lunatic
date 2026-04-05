# Lunatic Engine

A 3D game engine: Zig core + SDL3 GPU + LuaJIT scripting + zig-ecs.

## Goals

- **Performance**: engine core in Zig, fully ECS-based architecture
- **Hackable**: Optional Lua scripting for hot-reloadable system implementations; game projects fork and modify the engine repo for maximum flexibility
- **Agent friendly**: simple architecture and Lua API for easy integration with AI agents (e.g. via natural language descriptions of game logic)

## Details

- Components declare Lua semantics via a `pub const lua` struct literal: `.{ .name = "position" }` for data components, `.{ .name = "mesh", .resolve = .mesh }` for asset handles. Tag components (zero-sized structs) are auto-detected. Data component fields must be `f32` or `u32`. All Lua bridge dispatch goes through the `ComponentOps` vtable generated in `component_ops.zig`.
- Engine code is split by responsibility: `engine.zig` (lifecycle, registries, frame orchestration), `renderer.zig` (GPU pipeline, scene rendering), `postprocess.zig` (UE-style mip-chain bloom — GPU handles only, settings from Camera component), `lua_api.zig` (Lua bindings + ImGui `ui` table), `component_ops.zig` (comptime vtable generator). Both renderer and lua_api import the Engine type from engine.zig.
- Post-processing settings (exposure, bloom_intensity) live on the Camera component. bloom_intensity=0 means no bloom (just tonemapping). Bloom uses a 6-level progressive downsample/upsample mip chain (Jimenez SIGGRAPH 2014).
- Built-in systems: `flyCameraSystem` (attach `FlyCamera` component to a camera entity), `debugUiSystem` (ImGui post-processing controls). Both auto-registered at engine init.
- ImGui is exposed to Lua via the `ui` global table: `ui.begin_window`, `ui.end_window`, `ui.text`, `ui.separator_text`, `ui.slider_float`, `ui.checkbox`, `ui.button`. Slider/checkbox use functional style (take current value, return new value).
- Adding a new asset handle type (e.g. `TextureHandle` with string name resolution): define struct with `.resolve = .texture` in its `.lua` metadata, add to the `.all` tuple, add a `.texture` variant to `HandleKind` in `engine.zig`, and add a case to `Engine.resolveHandle()`'s switch.
- Zig systems are registered with `engine.addSystem(fn)` and run before Lua systems each frame. Pure Zig examples/games can skip Lua entirely. Core component types are accessible via `engine_mod.core_components`.

## Scale Target

The engine must handle tens of thousands to hundreds of thousands of entities efficiently, even if current demos are small. Design all per-entity paths (queries, iteration, rendering) with this scale in mind. Avoid per-entity allocations, per-entity `pcall`, or O(n²) patterns in hot loops.

## Conventions

- Use Conventional Commit formatting for commit messages
- `lc` = Lua C namespace (from `lua.zig`), `c` = SDL C namespace (from `engine.zig`). Both are `pub const` exports — other files must import these rather than doing their own `@cImport`.
- Any new APIs must be made available to Zig first, and then (optionally, where it makes sense) to Lua.
- Mesh winding order is CCW (counter-clockwise) when viewed from outside. Pipeline uses `CULLMODE_BACK` + `FRONTFACE_COUNTER_CLOCKWISE`. New geometry generators should verify winding with the cross-product dot normal test.

### Binary assets and Git LFS
- Binary assets (fonts, textures, models) go in `assets/` and are tracked via **Git LFS**. The `.gitattributes` file defines tracked patterns (`.ttf`, `.otf`, `.glb`, `.png`, `.jpg`, `.hdr`, etc.).
- When adding a new binary file type, run `git lfs track "*.ext"` before committing.
- Font: IBM Plex Sans (SIL Open Font License) in `assets/fonts/`, loaded by engine at init.

### zig-ecs patterns
- `registry.view()` for multi-component queries: iterate with `.entityIterator()` + `.get()`/`.getConst()`. Typed `.iterator()` and `.each()` are **group-only** — not available on views.
- `registry.group()` for persistent, signal-maintained entity sets. Use non-owning groups (`group(.{}, .{includes...}, .{})`) unless you need cache-friendly owned storage.
- Use `registry.add()` when you know the component isn't present. Use `addOrReplace()` only when it might already exist.

## Gotchas

- **Shared `@cImport`**: Each `@cImport` in Zig creates distinct opaque types. If two files each `@cImport("SDL3/SDL.h")`, their `SDL_GPUDevice` types are incompatible. Always import `c` from `engine.zig` and `lc` from `lua.zig`.
- **Shader cache staleness**: The zig build cache doesn't always invalidate spirv-cross MSL output when GLSL sources change. Run `rm -rf .zig-cache` after modifying shaders if you see stale behavior.
- **MSAA + multiple render passes**: Use `STOREOP_RESOLVE_AND_STORE` (not `STOREOP_RESOLVE`) when subsequent render passes need to load from the MSAA color texture. Plain RESOLVE discards MSAA contents.
- **Shared module graph**: `buildEngineModules()` in `build.zig` creates the full engine module graph. It's called twice (game executable + integration tests). When adding a new `.zig` engine module, add it there.
