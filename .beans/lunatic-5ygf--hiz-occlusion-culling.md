---
# lunatic-5ygf
title: HiZ Occlusion Culling
status: completed
type: feature
priority: normal
created_at: 2026-04-07T17:14:01Z
updated_at: 2026-04-07T17:30:42Z
---

Add hierarchical-Z occlusion culling using previous-frame depth reprojection. Phases: mesh AABBs, HiZ mip pyramid, compute shader occlusion test, frame loop integration.


## Tasks

- [x] Phase 1: Mesh AABBs — using bounding sphere (max scale) instead of AABB, cheaper and sufficient
- [x] Phase 2: HiZ mip pyramid — hiz_downsample.frag + per-level textures + combined mipmapped texture
- [x] Phase 3: Compute shader occlusion test — isOccluded() with bounding sphere projection + textureLod
- [x] Phase 4: Frame loop integration — buildHiZPyramid before scene pass, prev_vp/prev_camera_pos stored
- [x] Phase 5: Build system — hiz_downsample.frag added to addShaders in build.zig
- [x] Phase 6: Verified — all 3 scenes render correctly with HiZ enabled


## Summary of Changes

Implemented HiZ (hierarchical-Z) occlusion culling using previous-frame depth reprojection:
- New shader: `engine/shaders/postprocess/hiz_downsample.frag` — max-reduce downsample for depth pyramid
- `postprocess.zig` — HiZ state, pipeline, sampler, texture creation, `buildHiZPyramid()` function
- `renderer.zig` — expanded ComputeUniforms with prev_vp/prev_camera_pos/hiz_params, compute pipeline accepts samplers, dispatch binds HiZ
- `engine.zig` — prev_vp/prev_camera_pos fields, HiZ build integrated before scene pass
- `instance_setup.comp` — `isOccluded()` function: bounding sphere projection to previous frame screen space + HiZ depth test
- `build.zig` — hiz_downsample shader added
- `CLAUDE.md` — documented HiZ architecture and updated pipeline diagram
