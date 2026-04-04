---
# lunatic-n0qr
title: Generic component API for Lua
status: completed
type: task
priority: normal
created_at: 2026-04-04T08:38:20Z
updated_at: 2026-04-04T08:39:31Z
---

Replace per-component Lua functions (set_position, set_rotation, set_mesh, set_spin, get_position, get_rotation) with generic gammo.add(e, name, ...), gammo.set(e, name, ...), gammo.remove(e, name), gammo.get(e, name) that dispatch by component name string.

## Summary of Changes

Replaced per-component Lua functions with three generic functions:
- `gammo.add(e, name, ...)` — add or replace a component
- `gammo.get(e, name)` — read component values
- `gammo.remove(e, name)` — remove a component

Dispatch is by string name matching against known component types. Added helper functions entityFromLua() and componentName() to reduce boilerplate.
