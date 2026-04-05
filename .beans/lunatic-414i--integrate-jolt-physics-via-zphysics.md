---
# lunatic-414i
title: Integrate Jolt Physics via zphysics
status: completed
type: feature
priority: normal
created_at: 2026-04-05T15:12:37Z
updated_at: 2026-04-05T15:26:33Z
---

Add Jolt Physics as a dependency via zphysics. Create physics.zig module, RigidBody component, physics system for transform sync. Expose body creation to Lua.

## Summary of Changes

- Added zphysics (Jolt Physics via JoltC) as a Zig dependency
- New engine/src/physics.zig: PhysicsState, layer interfaces, init/deinit, physicsSystem (transform sync)
- RigidBody component (body_id: u32) added to core_components
- Physics system auto-registered, syncs Jolt body transforms → ECS Position/Rotation each frame
- Lua API: physics_add_box, physics_add_sphere, physics_add_floor, physics_optimize
- Game demo: 81 physics cubes/spheres fall onto a ground plane
- Re-exports key zphysics types (BodyId, Shape, BodyCreationSettings, etc.) for game Zig code
