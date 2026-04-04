---
# lunatic-lw2m
title: Material system with per-entity materials
status: completed
type: feature
priority: normal
created_at: 2026-04-04T13:32:16Z
updated_at: 2026-04-04T13:38:01Z
---

Add a material registry (parallel to mesh registry) with MaterialHandle ECS component. Materials start with albedo color (r,g,b). Split FragUniforms into global scene uniforms and per-entity material uniforms. Expose to Lua.

## Summary of Changes

Added a material system with per-entity material support:

- **MaterialData** struct (albedo color) + registry (parallel to mesh registry, 64 slots)
- **MaterialHandle** ECS component, added to component list for Lua bindings
- **Split FragUniforms** into SceneUniforms (slot 0, per-frame) and MaterialUniforms (slot 1, per-entity)
- **Fragment shader** updated to two uniform blocks (scene + material)
- **Lua API**: `lunatic.create_material(name, r, g, b)` to register materials, `lunatic.add(e, "material", name)` to assign
- **game/main.lua** updated to create colored materials and randomly assign them to cubes
