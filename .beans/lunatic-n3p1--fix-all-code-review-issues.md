---
# lunatic-n3p1
title: Fix all code review issues
status: completed
type: task
priority: normal
created_at: 2026-04-04T19:20:02Z
updated_at: 2026-04-04T19:31:18Z
---

Address all issues from codebase review: extract AssetStore, u32 indices, separate query generation, reduce lua_api duplication, add Scale component, expose material properties, wire tests.zig, fix build duplication, add dt to renderer, fix tangents, homebrew TODOs

## Summary of Changes

All 11 code review issues addressed:

1. **Separated query_generation from current_frame** — engine.zig now has distinct counters for cache invalidation vs frame tracking
2. **u32 indices** — geometry.zig, engine.zig, renderer.zig, gltf.zig all use u32, supporting meshes >65K vertices
3. **Wired tests.zig into zig build test** — 26 integration tests now run alongside math3d and geometry unit tests (46 total)
4. **Fixed double-build of pbr_test** — default 'run' step reuses the exe from the examples loop
5. **Added TODO for hardcoded homebrew paths** in build.zig
6. **Added Scale component** to core_components.zig (x, y, z defaults to 1,1,1) with auto Lua bindings
7. **Scale used in renderer model matrix** — translate * rotation * scale; added Mat4.scale() to math3d.zig
8. **Gave MeshHandle, MaterialHandle, LookAt proper Lua bindings** — removed ~40 lines of special-case code in lua_api.zig luaGet; kept resolveHandle for string name resolution in luaAdd
9. **Exposed metallic, roughness, emissive** in luaCreateMaterial
10. **Passed dt to renderer.renderSystem** for future GPU-side animation
11. **Fixed cube and sphere tangents** — cube writes per-face tangent from UV direction; sphere computes tangent as dPos/dTheta
12. **Extracted AssetStore struct** from Engine — groups mesh/material/texture registries with their own findMesh/findMaterial/deinit methods
