---
# lunatic-thni
title: 3D rendering with SDL3 GPU API
status: completed
type: feature
priority: normal
created_at: 2026-04-03T16:25:12Z
updated_at: 2026-04-03T17:09:17Z
---

Replace 2D renderer with SDL3 GPU pipeline. Vertex/fragment shaders, vertex buffers, uniform buffers, 3D math (mat4, projection, view), and a rotating cube rendered with actual GPU triangles. Expose camera and mesh API to Lua.

## Summary of Changes

- Replaced SDL3 2D renderer with SDL3 GPU API (Metal backend on macOS)
- Added `src/math3d.zig` with Vec3, Mat4 (perspective, lookAt, rotation, multiply)
- Vertex + fragment shaders in MSL, embedded as string literals
- 36-vertex colored cube with depth buffer
- Lua API: `set_camera()`, `set_rotation()`, `set_clear_color()`, `key_down()`
- Camera orbit demo driven from Lua with arrow keys
