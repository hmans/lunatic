---
# lunatic-l9qz
title: UE-style bloom with progressive mip chain
status: completed
type: feature
priority: normal
created_at: 2026-04-05T12:40:22Z
updated_at: 2026-04-05T12:47:39Z
---

Replace single-pass Gaussian bloom with Jimenez-style progressive downsample/upsample mip chain. 13-tap downsample with Karis average, 9-tap tent upsample, per-level tinting.

## Summary of Changes

- Replaced single-pass Gaussian bloom with UE-style progressive mip-chain bloom (Jimenez SIGGRAPH 2014)
- New downsample.frag: 13-tap anti-aliased downsample with Karis average on first pass
- New upsample.frag: 9-tap tent filter with additive blending via LOADOP_LOAD
- 6-level mip chain with per-level tinting (UE4-inspired default weights)
- Removed threshold/blur shaders and related Camera fields (threshold, soft_knee, blur_passes)
- Camera now has just exposure + bloom_intensity (simpler, more physically based)
- Additive blend pipeline for upsample passes
- Old threshold.frag and blur.frag kept in shaders/ but no longer compiled
