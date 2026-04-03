---
# gammo-l5gr
title: Immediate-mode draw API + Lua ECS
status: completed
type: feature
priority: normal
created_at: 2026-04-03T17:27:39Z
updated_at: 2026-04-03T17:32:05Z
---

Replace hardcoded cube with immediate-mode gammo.draw_mesh() API. Add mesh registry on Zig side. Build lightweight ECS in pure Lua. Kill global model_position/model_rotation state.

## Summary of Changes

- Replaced hardcoded single-cube rendering with immediate-mode `gammo.draw_mesh(name, x,y,z, rx,ry,rz)`
- Added mesh registry (name → GPU buffer + vertex count)
- Added per-frame draw list (up to 4096 draw commands)
- Removed `set_position`, `set_rotation` globals
- Built pure-Lua ECS in `game/ecs.lua`: spawn, despawn, set, get, remove, query with iterator
- Demo spawns 25 spinning cubes in a grid + a player-controlled cube
- Added `game/` to Lua package.path for require() support
