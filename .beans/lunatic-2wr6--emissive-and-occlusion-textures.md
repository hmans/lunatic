---
# lunatic-2wr6
title: Emissive and occlusion textures
status: completed
type: task
priority: normal
created_at: 2026-04-04T16:52:04Z
updated_at: 2026-04-04T16:57:25Z
parent: lunatic-8rb3
blocked_by:
    - lunatic-666x
---

Extend MaterialData with optional emissive texture + emissive factor (vec3), optional occlusion texture. Fragment shader: add emissive after lighting, multiply ambient by occlusion. Update GLTF loader.

## Summary of Changes

Emissive and occlusion were implemented as part of the metallic/roughness and BRDF tasks:
- Emissive: factor + texture, additive after lighting
- Occlusion: texture modulates ambient term
- Both read from GLTF materials
