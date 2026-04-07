---
# lunatic-m5ek
title: Migrate ECS from zig-ecs to flecs
status: completed
type: task
priority: normal
created_at: 2026-04-06T12:49:34Z
updated_at: 2026-04-06T13:20:31Z
---

Replace zig-ecs (prime31) with flecs via zflecs (zig-gamedev) wrapper. Involves updating build.zig.zon, build.zig, and all engine files that use the ECS: engine.zig, renderer.zig, lua_api.zig, component_ops.zig.

## Summary of Changes

Replaced zig-ecs (prime31) with flecs (via zig-gamedev/zflecs) as the ECS backend.

### Files changed:
- **build.zig.zon**: Replaced `entt` dependency with `zflecs`
- **build.zig**: Updated dependency wiring, added flecs C library linking, added zflecs module to physics
- **engine/src/engine.zig**: `registry: ecs.Registry` → `world: *ecs.world_t`, added `queryInit` helper, explicit component registration at init, all view/group patterns → flecs queries
- **engine/src/component_ops.zig**: Full rewrite — vtable now takes `*Engine` instead of `*ecs.Registry`, uses `ecs.get/set/has_id/get_mut` directly, runtime `idFn` for component IDs
- **engine/src/renderer.zig**: All `registry.*` calls → `ecs.get/has_id`, views → transient flecs queries
- **engine/src/lua_api.zig**: Entity type u32 → u64, LiveQuery uses `ecs.entity_t`, query functions use flecs queries natively instead of smallest-set-filter pattern
- **engine/src/physics.zig**: All view patterns → flecs queries

### Key design decisions:
- Entity IDs are now u64 (flecs entity_t) instead of u32 packed struct
- Queries are created transiently per use (create → iterate → fini) — can be optimized to cached queries later
- Component registration is explicit at engine init via `ecs.COMPONENT/TAG`
- `queryInit` helper simplifies query_desc_t construction from ID slices
- LookAt.target remains u32 for Lua bridge compat, cast to u64 at use site
