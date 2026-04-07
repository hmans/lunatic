---
# lunatic-p8e1
title: GPU Frustum Culling via Compute Shader
status: completed
type: feature
priority: normal
created_at: 2026-04-07T15:26:35Z
updated_at: 2026-04-07T15:29:01Z
---

## Tasks

- [x] Update ComputeUniforms with frustum planes + cull flag
- [x] Update instance_setup.comp with frustum plane extraction and sphere test
- [x] Extract frustum planes from VP matrix in Zig dispatch code
- [x] Enable culling for scene pass, skip for shadow passes
- [x] Verify rendering correctness with examples

## Summary of Changes

Added GPU frustum culling to the instance setup compute shader. Entities outside the camera frustum get zeroed MVPs (degenerate triangles = no rasterization/fragment cost).

- Frustum planes extracted from VP matrix using Griggs-Hartmann method (normalized)
- Bounding sphere test: conservative radius from max(abs(scale.xyz)), assumes mesh fits unit sphere
- Scene pass: frustum culling enabled. Shadow passes: culling disabled (shadow caster logic only)
- No compaction yet — culled entities occupy slots with zeroed data. Future phase adds indirect draw.
