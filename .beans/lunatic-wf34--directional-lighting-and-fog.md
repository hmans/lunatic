---
# lunatic-wf34
title: Directional lighting and fog
status: completed
type: feature
priority: normal
created_at: 2026-04-03T17:36:26Z
updated_at: 2026-04-03T17:40:59Z
---

Replace per-vertex colors with normals. Add directional light in fragment shader. Add distance fog configurable from Lua (fog color, start, end).

## Summary of Changes

- Vertex format changed from position+color to position+normal
- Cube mesh now has proper face normals, white albedo
- Vertex shader passes world-space position and normal via model matrix
- Fragment shader: half-Lambert directional lighting, configurable ambient, linear distance fog
- New Lua API: set_fog(start, end, r,g,b), set_light(dx,dy,dz), set_ambient(r,g,b)
- Fragment uniforms struct (std140) with light, camera, fog, albedo, ambient
- Demo uses sky-blue clear color with matching fog, 9x9 grid
