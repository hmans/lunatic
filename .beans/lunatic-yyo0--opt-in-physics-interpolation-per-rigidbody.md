---
# lunatic-yyo0
title: Opt-in physics interpolation per RigidBody
status: completed
type: feature
priority: normal
created_at: 2026-04-09T10:32:30Z
updated_at: 2026-04-09T10:35:23Z
---

Add PhysicsInterpolation component. When present on a rigid body entity, store previous/current physics transforms and lerp at render time for smooth motion between physics steps.

## Summary

Added PhysicsInterpolation component to core_components. When present on a rigid body entity, the physics system stores prev/current transforms instead of writing Position/Rotation directly. A new physicsInterpolationSystem on PreStore lerps between them every frame. Opt-in: add PhysicsInterpolation to any entity. Physics rain demo uses it on all spawned spheres.
