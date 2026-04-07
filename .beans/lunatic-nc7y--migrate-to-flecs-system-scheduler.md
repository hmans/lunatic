---
# lunatic-nc7y
title: Migrate to flecs system scheduler
status: completed
type: task
priority: normal
created_at: 2026-04-06T13:41:58Z
updated_at: 2026-04-06T13:49:44Z
---

Replace the custom system scheduler (SystemEntry, runAllSystems, addSystem) with flecs's built-in pipeline scheduler. Enables future multi-threading via ecs.set_threads().

## Summary of Changes

Migrated from the custom system scheduler (SystemEntry array, runAllSystems) to the flecs pipeline scheduler.

### What changed:
- Zig systems (age, physics, fly_camera, stats_overlay) registered with `ecs.SYSTEM()` and run via `ecs.progress()`
- Lua systems still managed by a custom list (LuaJIT is single-threaded) but dispatched through a flecs system callback
- `SystemEntry` replaced with `LuaSystemEntry` (simpler, Lua-only)
- `runAllSystems()` removed — `ecs.progress(dt)` is the single tick entry point
- `tickSystems(dt)` public method added for tests/headless mode
- REST API moved to non-headless init to avoid test interference
- Stats overlay updated to show only Lua system timing (Zig systems visible in flecs Explorer)

### Future: multi-threading
With systems in the flecs pipeline, enabling multi-threading is now a single call:
```zig
ecs.set_threads(world, 4);
```
Flecs will automatically parallelize Zig systems that operate on disjoint component sets.
