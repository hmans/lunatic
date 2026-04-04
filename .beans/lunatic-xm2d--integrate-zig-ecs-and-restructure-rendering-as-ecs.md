---
# lunatic-xm2d
title: Integrate zig-ecs and restructure rendering as ECS system
status: completed
type: feature
priority: normal
created_at: 2026-04-04T08:25:26Z
updated_at: 2026-04-04T08:34:36Z
---

Pull in zig-ecs library, define Position/Rotation/Mesh components, restructure the render loop as a Zig system that queries the registry. Step 1: get zig-ecs building. Step 2: define components and render system.

## Summary of Changes

- Integrated zig-ecs (EnTT port) as a build dependency
- Defined components in `src/components.zig`: Position, Rotation, MeshHandle, Spin
- Render loop is now a Zig system querying Position+Rotation+MeshHandle from the ECS registry
- Spin system runs in Zig, iterates Rotation+Spin components
- Removed draw list, DrawCmd, and Lua-side ECS
- New Lua API: spawn(), destroy(), set_position(), set_rotation(), set_mesh(), set_spin(), get_position(), get_rotation()
- Lua creates entities via gammo.spawn() and sets Zig-side components
- game/main.lua updated to use new API, player movement stays in Lua
