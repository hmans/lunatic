---
# lunatic-8rb3
title: PBR rendering
status: completed
type: epic
priority: normal
created_at: 2026-04-04T16:52:04Z
updated_at: 2026-04-04T16:57:25Z
---

Physically-based rendering: metallic/roughness workflow, normal mapping, emissive, occlusion. Replace half-Lambert with Cook-Torrance BRDF.

## Summary of Changes

Full PBR pipeline:
- Cook-Torrance BRDF (GGX + Smith-Schlick + Fresnel-Schlick)
- Metallic/roughness workflow with texture support
- Normal mapping with TBN matrix from tangent vectors
- Emissive + occlusion textures
- Reinhard tone mapping + gamma correction
- 5 texture slots per material, dummy texture for unused slots
