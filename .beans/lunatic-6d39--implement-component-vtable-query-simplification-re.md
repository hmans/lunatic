---
# lunatic-6d39
title: Implement component vtable + query simplification + renderer decomposition
status: completed
type: task
priority: normal
created_at: 2026-04-04T19:52:35Z
updated_at: 2026-04-04T20:00:55Z
---

Implement the three-phase refactoring from docs/design-component-vtable-and-renderer-decomposition.md

## Summary of Changes

All three phases implemented:

**Phase 1: Component vtable + metadata + asset handle crystallization**
- New `component_ops.zig` generates a `ComponentOps` vtable per component at comptime
- Components declare `.lua = .{ .name = "...", .resolve = .mesh }` metadata
- All 7 `inline for (components.all)` loops in lua_api.zig eliminated
- MeshHandle/MaterialHandle no longer special-cased
- `resolveHandle` moved to Engine as public method

**Phase 2: Query cache elimination**  
- Removed `QueryCacheEntry`, `query_generation`, all cache helpers
- `lunatic.query()` builds fresh table each call (no cache)
- New `lunatic.each()` provides zero-allocation callback iteration
- Engine struct simplified (2 fields removed)

**Phase 3: Renderer decomposition**
- Extracted `gatherLights()`, `buildDrawList()`, `submitDrawCalls()`
- Draw list built once per frame (was per-camera — latent multi-camera bug fixed)
- `renderSystem()` reduced from 264 to ~80 lines
