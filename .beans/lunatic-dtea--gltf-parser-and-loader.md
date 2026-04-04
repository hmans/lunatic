---
# lunatic-dtea
title: GLTF parser and loader
status: completed
type: task
priority: normal
created_at: 2026-04-04T16:24:30Z
updated_at: 2026-04-04T16:46:45Z
parent: lunatic-8uei
blocked_by:
    - lunatic-13gg
---

Add cgltf as a C dependency. New gltf.zig module that parses a .gltf/.glb file and creates mesh + material + texture resources via Engine APIs. Lua API: load_gltf(path) returning a table of mesh/material handles.

## Summary of Changes

GLTF/GLB loading:
- cgltf vendored, compiled via build.zig
- gltf.zig parses meshes (indexed vertices + normals + UVs), PBR materials (base color factor + texture), and embedded/external images
- Lua: load_gltf(path) returns table of mesh and material handle arrays
- Dummy 1x1 white texture ensures sampler is always bound
- DamagedHelmet.glb renders with base color texture
