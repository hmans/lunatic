# Lunatic Engine

A 3D game engine: Zig core + SDL3 GPU + LuaJIT scripting + zig-ecs.

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
- `game/main.zig` — game entry point (minimal: init, load script, run)
- `game/main.lua` — game logic (scene setup, systems, debug UI)
- `game/components.zig` — game-specific components (extends core with Spin, Player, etc.)
- `assets/` — binary assets tracked via Git LFS (fonts, textures, models)
- `mcp/` — MCP server for Claude Code integration (Node.js)

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
- **HDR specular fireflies**: The fragment shader clamps output to 64.0 and uses specular anti-aliasing (`fwidth(N)`) to prevent GGX peaks from flickering. If you see flashing bright pixels, check these.
- **HDR clear/fog colors**: User-specified sRGB colors are inverse-ACES-transformed in `renderer.zig` so they round-trip correctly through the tonemap. When changing the tonemapper, update `srgbToHdr()`.
- **DoF depth storage**: Linear depth is stored in the HDR texture's alpha channel (written in `default.frag`). Clear color alpha is set to 1000.0 for background/sky. New fragment shaders must write linear depth to alpha.
- **PostProcess texture ping-pong**: DoF composite writes to `hdr_texture_b` then swaps with `hdr_texture` to avoid read-write hazards. Bloom and final composite read from whichever is current.
