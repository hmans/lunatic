---
# lunatic-3lth
title: Metallic/roughness material properties
status: completed
type: task
priority: normal
created_at: 2026-04-04T16:52:04Z
updated_at: 2026-04-04T16:54:53Z
parent: lunatic-8rb3
---

Extend MaterialData with metallic (f32) and roughness (f32) factors + optional metallic_roughness texture. Update MaterialUniforms. Update GLTF loader to read pbr_metallic_roughness factors and texture. Fragment shader uses these for lighting but keeps simple diffuse for now (full BRDF comes later).

## Summary of Changes

Extended material system for full PBR:
- MaterialData: metallic, roughness, emissive factor, 5 texture slots (base_color, metallic_roughness, normal, emissive, occlusion)
- MaterialUniforms: material_params, texture_flags, emissive vectors
- 5 sampler slots bound per material (dummy texture for unused slots)
- GLTF loader reads all PBR properties and texture references
- Fragment shader wired for emissive + occlusion (BRDF comes next)
