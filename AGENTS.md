# Lunatic Engine

A 3D game engine: Zig core + SDL3 GPU + LuaJIT scripting + flecs ECS. Please refer to the repository's [README.md](README.md) for an overview of the project.

## Goals

- **Performance**: engine core in Zig, fully ECS-based architecture
- **Hackable**: Optional Lua scripting for hot-reloadable system implementations; game projects fork and modify the engine repo for maximum flexibility
- **Agent friendly**: simple architecture and Lua API for easy integration with AI agents (e.g. via natural language descriptions of game logic)

## Project Structure

- `engine/src/` — engine core (Zig)
- `engine/shaders/scene/` — scene rendering shaders (default.vert/frag)
- `engine/shaders/shadow/` — shadow map shaders (shadow.vert/frag)
- `engine/shaders/postprocess/` — post-processing shaders (bloom, DoF, composite, etc.)
- `engine/vendor/` — vendored C/C++ libs (stb_image, cgltf, Dear ImGui + dcimgui)
- `game/` — user's game project (skeleton: main.zig, components.zig, main.lua)
- `examples/` — demo scenes and example game code
- `assets/` — binary assets tracked via Git LFS (fonts, textures, models)
- `mcp/` — MCP server for Claude Code integration (Node.js)

### Build targets

- `zig build run` — build and run the game (`game/`)
- `zig build run-examples` — build and run the examples (`examples/`)
- `zig build test` — run all tests

Each target has its own `components.zig` for game-specific components. The engine's `loadScript()` sets `package.path` from the script's directory, so `require("scenes.foo")` resolves relative to the script.

## Details

- Components declare Lua semantics via a `pub const lua` struct literal: `.{ .name = "position" }` for data components, `.{ .name = "mesh", .resolve = .mesh }` for asset handles. Tag components (zero-sized structs) are auto-detected. Data component fields must be `f32` or `u32`. All Lua bridge dispatch goes through the `ComponentOps` vtable generated in `component_ops.zig`. Missing trailing args in Lua `add()` calls use struct defaults.
- Engine code is split by responsibility: `engine.zig` (lifecycle, registries, frame orchestration, built-in systems), `renderer.zig` (GPU pipeline, scene rendering), `postprocess.zig` (bloom, DoF, composite+tonemap — GPU handles only, settings from Camera component), `lua_api.zig` (Lua bindings + ImGui `ui` table), `component_ops.zig` (comptime vtable generator), `debug_server.zig` (HTTP debug server + request queue).
- Adding a new asset handle type (e.g. `TextureHandle` with string name resolution): define struct with `.resolve = .texture` in its `.lua` metadata, add to the `.all` tuple, add a `.texture` variant to `HandleKind` in `engine.zig`, and add a case to `Engine.resolveHandle()`'s switch.

### Post-Processing Pipeline

All post-processing settings live on the **Camera component** (per-camera). Pipeline order:

```
Scene → HDR texture (R16G16B16A16_FLOAT, linear depth in alpha)
  → DoF (if dof_focus_dist > 0): CoC → prefilter → bokeh gather → tent filter → composite
  → Bloom (if bloom_intensity > 0): 6-level mip-chain downsample → upsample with per-level tints
  → Final composite → swapchain: bloom add, exposure, color temp, ACES tonemap, gamma, vignette, chromatic aberration, film grain
  → ImGui overlay (LDR, directly to swapchain)
```

Camera post-processing fields: `exposure`, `bloom_intensity`, `dof_focus_dist`, `dof_focus_range`, `dof_blur_radius`, `vignette`, `vignette_smoothness`, `chromatic_aberration`, `grain`, `color_temp`.

Global bloom shape: `engine.postprocess.tints[0..6]` (per-level weights) and `engine.postprocess.radius` (upsample filter width). Tweakable via `lunatic.get/set_bloom_tints()` and `lunatic.get/set_bloom_radius()`.

### Built-in Systems

Auto-registered at engine init:
- **`flyCameraSystem`**: Attach `FlyCamera` component to a camera entity. Right-click to activate (hides cursor), WASD + Space/Ctrl to move. Configurable speed/sensitivity.
- **`debugUiSystem`**: ImGui debug panel with post-processing controls.

### ImGui

- Vendored: Dear ImGui v1.92.7 + dcimgui (dear_bindings) C wrapper + SDL3/GPU backends
- `@cImport` block in `engine.zig` includes `cimgui.h` + `cimgui_impl_sdlgpu3.h` alongside SDL3 (shared opaque types)
- C function prefix: `ig` (e.g. `c.igBegin`, `c.igSliderFloat`)
- Custom dark theme with IBM Plex Sans font (HiDPI-aware, rasterized at native resolution)
- Exposed to Lua via `ui` global table: `begin_window`, `end_window`, `text`, `separator_text`, `slider_float`, `checkbox`, `button`, `collapsing_header`, `set_next_window_pos`, `set_next_window_size`, `fps`. Slider/checkbox use functional style (take current value, return new value).

### Flecs Explorer (ECS inspection)

The engine exposes a flecs REST API on `localhost:27750` for real-time ECS inspection via the [Flecs Explorer](https://www.flecs.dev/explorer). Open the Explorer in a browser while the engine is running to:

- Browse all entities and their component values
- Edit component fields live (positions, camera settings, light colors, etc.)
- Run queries using the flecs query DSL (use fully qualified names, e.g. `core_components.Position`)
- View archetype statistics and world structure

The REST API can also be queried directly:
```sh
curl http://localhost:27750/world                              # All entities + components
curl "http://localhost:27750/query?expr=core_components.Camera" # Query entities
curl http://localhost:27750/entity/flecs                        # Specific entity
```

### Debug Server (HTTP API + MCP)

The engine runs an embedded HTTP debug server on `localhost:19840` (background thread, started automatically in `Engine.run()`). This is the primary interface for agent-driven inspection and control.

**Endpoints:**

| Endpoint | Method | Description |
|---|---|---|
| `/stats` | GET | JSON: FPS, entity count, draw calls, physics stats, per-phase GPU timing |
| `/lua` | POST | Evaluate Lua code (body = code string), returns JSON result |
| `/screenshot` | POST | Capture current frame, returns PNG bytes |

**Architecture:** The HTTP thread accepts connections and queues requests. The main thread drains the queue once per frame (after `runAllSystems()`, before rendering). For `/lua` and `/stats`, the HTTP thread blocks until the main thread processes the request. For `/screenshot`, the response is deferred until after the frame renders and the PNG is written.

**MCP server** (`mcp/server.mjs`): Thin Node.js wrapper that exposes the HTTP API as MCP tools (`eval_lua`, `screenshot`, `get_stats`). Configured in `.mcp.json` for auto-discovery by Claude Code. Install deps with `cd mcp && npm install`.

**Testing manually:**
```sh
curl http://localhost:19840/stats
curl -d 'return lunatic.get_stats()' http://localhost:19840/lua
curl -X POST http://localhost:19840/screenshot -o screenshot.png
```

### Screenshots (file-based, legacy)

A file-based screenshot mechanism also exists for use without the debug server. All files live in `tmp/` (gitignored):

1. `mkdir -p tmp && touch tmp/<name>.request`
2. The engine detects and deletes the trigger on the next frame
3. The rendered frame (including ImGui overlay) is saved to `tmp/<name>.png`

On Metal, the swapchain texture is framebufferOnly, so the engine renders to an intermediate texture, blits to the swapchain, and downloads from the intermediate. This adds one frame of GPU sync (fence wait) only on screenshot frames.

## Running the Engine as an Agent

You are encouraged to run the engine to test changes, inspect state, and take screenshots. Both the game and the examples suite are available:

```sh
zig build run               # game (game/main.lua)
zig build run-examples      # examples suite (examples/main.lua)
```

Run these in the background. The engine opens a window and starts its main loop; the HTTP APIs become available once you see `[debug-server] listening on http://127.0.0.1:19840` in the output.

### Interacting with the running engine

**Debug server** (primary interface, `localhost:19840`):

```sh
curl http://localhost:19840/stats                           # JSON: FPS, entity count, GPU timing
curl -d 'return lunatic.get_stats()' http://localhost:19840/lua  # Evaluate arbitrary Lua
curl -X POST http://localhost:19840/screenshot -o screenshot.png # Capture current frame
```

The `/lua` endpoint is the most powerful — you can spawn/destroy entities, modify components, change camera settings, query the ECS, or run any code available to Lua scripts.

**Flecs REST API** (ECS inspection, `localhost:27750`):

```sh
curl http://localhost:27750/world                                # All entities + components
curl "http://localhost:27750/query?expr=core_components.Camera"  # Query by component
curl http://localhost:27750/entity/flecs                         # Specific entity
```

**MCP tools**: If the MCP server is running (`mcp/server.mjs`), you also have `eval_lua`, `screenshot`, and `get_stats` available as MCP tool calls.

### Process lifecycle — IMPORTANT

**Always kill the engine process when you're done with it.** The engine holds the GPU, audio device, and network ports. Leaving it running wastes resources and blocks subsequent launches.

```sh
pkill -f "lunatic" 2>/dev/null    # Kill by process name
```

Do this:
- After verifying a change looks correct
- Before starting a new build (the old process holds the ports)
- When switching between `run` and `run-examples`
- At the end of any task that involved running the engine

If you forget, the next `zig build run` will succeed but the debug server will fail to bind its port, and MCP tools won't work.

## Scale Target

The engine must handle tens of thousands to hundreds of thousands of entities efficiently, even if current demos are small. Design all per-entity paths (queries, iteration, rendering) with this scale in mind. Avoid per-entity allocations, per-entity `pcall`, or O(n²) patterns in hot loops.

## IMPORTANT: Verify with examples

**Any change to the engine MUST be verified against the examples suite.** Run `zig build run-examples` and confirm the examples still work correctly before committing engine changes. The examples exercise shadows, clustered lighting, post-processing, physics, and scene management — if they break, the engine is broken.

## Conventions

- **Document all code thoroughly.** Shader code (GLSL), Zig engine code, and Lua scripts must include clear, helpful comments that explain the *why* and *how* — not just the *what*. Assume the reader is a human or AI agent who understands programming but may not know the engine's specific conventions, GPU pipeline details, or rendering math. Include references to techniques and papers where applicable. This codebase should be learnable by reading it.
- Use Conventional Commit formatting for commit messages
- `lc` = Lua C namespace (from `lua.zig`), `c` = SDL C namespace (from `engine.zig`). Both are `pub const` exports — other files must import these rather than doing their own `@cImport`.
- Any new APIs must be made available to Zig first, and then (optionally, where it makes sense) to Lua.
- Mesh winding order is CCW (counter-clockwise) when viewed from outside. Pipeline uses `CULLMODE_BACK` + `FRONTFACE_COUNTER_CLOCKWISE`. New geometry generators should verify winding with the cross-product dot normal test.

### Binary assets and Git LFS
- Binary assets (fonts, textures, models) go in `assets/` and are tracked via **Git LFS**. The `.gitattributes` file defines tracked patterns (`.ttf`, `.otf`, `.glb`, `.png`, `.jpg`, `.hdr`, etc.).
- When adding a new binary file type, run `git lfs track "*.ext"` before committing.
- Font: IBM Plex Sans (SIL Open Font License) in `assets/fonts/`, loaded by engine at init.

### flecs (ECS) patterns
- The ECS world is `Engine.world: *ecs.world_t`. Import `ecs` as `@import("zflecs")`.
- Components must be registered at init: `ecs.COMPONENT(world, T)` for data components, `ecs.TAG(world, T)` for zero-sized tags. This happens in `Engine.init()`.
- Entity IDs are `ecs.entity_t` (u64). Create with `ecs.new_id(world)`, destroy with `ecs.delete(world, entity)`.
- Component access: `ecs.get(world, entity, T)` returns `?*const T`, `ecs.get_mut(world, entity, T)` returns `?*T`, `ecs.set(world, entity, T, value)` adds or replaces.
- Queries: use `queryInit(world, &.{id1, id2}, &.{exclude_id})` helper from `engine.zig`, iterate with `while (ecs.query_next(&it)) for (it.entities()) |entity| { ... };`, finalize with `ecs.query_fini(q)`.
- **Important**: `ecs.query_next` calls `ecs.iter_fini` internally when returning false. Do NOT call `ecs.iter_fini` on a fully-consumed iterator — it causes a double-free crash. Only call it when breaking out of iteration early.
- `ecs.id(T)` returns the runtime component ID — cannot be used at comptime (use `idFn` closures instead).
- **System dispatch**: All Zig + Lua systems are dispatched by a single flecs `callback` system (`engineSystemsCallback`). It uses `ecs.defer_suspend`/`defer_resume` so mutations apply immediately (our systems read-after-write in the same frame). Do NOT use `run` callbacks for zero-term systems — it causes double iterator finalization (flecs issue #905).
- **Shutdown**: `ecs_fini` is skipped in non-headless mode because the flecs REST server's internal iterators trigger a spurious stack leak assertion. Headless tests call `ecs_fini` normally.

## Gotchas

- **Shared `@cImport`**: Each `@cImport` in Zig creates distinct opaque types. If two files each `@cImport("SDL3/SDL.h")`, their `SDL_GPUDevice` types are incompatible. Always import `c` from `engine.zig` and `lc` from `lua.zig`.
- **Shader cache staleness**: GLSL sources are tracked as build dependencies via `addFileArg(b.path(...))` in `build.zig`, so `glslc` and `spirv-cross` should re-run automatically when shaders change. If you still see stale behavior, run `rm -rf .zig-cache` as a last resort.
- **MSAA + multiple render passes**: Use `STOREOP_RESOLVE_AND_STORE` (not `STOREOP_RESOLVE`) when subsequent render passes need to load from the MSAA color texture. Plain RESOLVE discards MSAA contents.
- **Shared module graph**: `buildEngineModules()` in `build.zig` creates the full engine module graph. It's called twice (game executable + integration tests). When adding a new `.zig` engine module, add it there.
- **HDR specular fireflies**: The fragment shader clamps output to 64.0 and uses specular anti-aliasing (`fwidth(N)`) to prevent GGX peaks from flickering. If you see flashing bright pixels, check these.
- **HDR clear/fog colors**: User-specified sRGB colors are inverse-ACES-transformed in `renderer.zig` so they round-trip correctly through the tonemap. When changing the tonemapper, update `srgbToHdr()`.
- **DoF depth storage**: Linear depth is stored in the HDR texture's alpha channel (written in `default.frag`). Clear color alpha is set to 1000.0 for background/sky. New fragment shaders must write linear depth to alpha.
- **PostProcess texture ping-pong**: DoF composite writes to `hdr_texture_b` then swaps with `hdr_texture` to avoid read-write hazards. Bloom and final composite read from whichever is current.
- **Metal Y-flip for shadow sampling**: On Metal, clip space Y is inverted relative to texture UV space when rendering to custom textures (non-swapchain). When sampling a shadow atlas (or any render-to-texture target), flip Y in the UV computation: use `(-sc.y) * 0.5 + 0.5` instead of `sc.y * 0.5 + 0.5`. The swapchain doesn't need this because SDL3 GPU handles the flip internally. This applies to any shader that reprojects world positions into a previously-rendered texture's UV space.
- **Shadow cascade tuning**: Cascade splits use a log/uniform blend controlled by `cascade_lambda` (0.0 = uniform, 1.0 = logarithmic) in `renderer.zig`. The shadow far distance is capped independently of the camera far (`@min(cam.far, 80.0)`). Lower lambda and shorter shadow far distribute cascades more evenly across the visible scene. Current: `cascade_lambda = 0.5`, shadow far = 80.
