---
# lunatic-0exj
title: Normal mapping
status: completed
type: task
priority: normal
created_at: 2026-04-04T16:52:04Z
updated_at: 2026-04-04T16:57:25Z
parent: lunatic-8rb3
blocked_by:
    - lunatic-666x
---

Tangent vectors in Vertex (vec4, w=handedness). Compute tangent frame in vertex shader (TBN matrix). Sample normal map in fragment shader, transform to world space. Extend MaterialData with optional normal texture. Update GLTF loader to read tangents and normal textures.

## Summary of Changes

Normal mapping:
- Vertex extended with tangent vec4 (xyz + w=handedness)
- Pipeline vertex attribute location 3 = FLOAT4
- Vertex shader computes TBN matrix (tangent, bitangent, normal)
- Fragment shader samples normal map, transforms to world space via TBN
- GLTF loader reads tangent attribute when present
