---
# lunatic-t067
title: Compute normal matrix in instance_setup for non-uniform scale
status: completed
type: task
priority: normal
created_at: 2026-04-09T11:11:38Z
updated_at: 2026-04-09T17:52:44Z
---

Enables correct normals with non-uniform scale

## Summary of Changes\n\nCompute the normal matrix (inverse-transpose of model 3x3) for correct normals under non-uniform scale. Rather than adding a full mat3 per instance (+48 bytes), packs `1/scale²` into the unused `flags.yzw` (zero extra memory). The vertex shader reconstructs the transform as `model * (normal * inv_scale_sq)`, which equals `R·S⁻¹·n`.\n\n### Files changed\n- `instance_setup.comp` — compute `1/scale²` and write to `flags.yzw` in the scene pass\n- `default.vert` — use `flags.yzw` for normal transform, Gram-Schmidt re-orthogonalize tangent\n- `renderer.zig` — CPU fallback path also writes `1/scale²` into flags\n- `shadow.vert` — no changes needed (doesn't use normals)
