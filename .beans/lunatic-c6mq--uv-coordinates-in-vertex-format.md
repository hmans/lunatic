---
# lunatic-c6mq
title: UV coordinates in vertex format
status: completed
type: task
priority: normal
created_at: 2026-04-04T16:24:30Z
updated_at: 2026-04-04T16:30:50Z
parent: lunatic-8uei
blocked_by:
    - lunatic-rd2h
---

Extend Vertex with u/v fields. Update pipeline vertex attributes (location 2). Update vertex shader to pass UVs to fragment. Update geometry generators to emit UVs (cube: per-face 0-1, sphere: from theta/phi).

## Summary of Changes

Added UV coordinates:
- Vertex struct extended with u/v fields
- Pipeline vertex attributes: location 2 = FLOAT2 for UVs
- Vertex shader passes frag_uv to fragment shader
- Fragment shader receives frag_uv (not sampled yet)
- Cube: per-face 0-1 UVs. Sphere: UVs from theta/phi.
