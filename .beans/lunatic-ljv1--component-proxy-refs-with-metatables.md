---
# lunatic-ljv1
title: Component proxy refs with metatables
status: completed
type: feature
priority: normal
created_at: 2026-04-04T09:17:04Z
updated_at: 2026-04-08T14:15:57Z
---

Add gammo.ref(e, component_name) that returns a Lua userdata proxy with __index/__newindex metamethods dispatching to Zig ECS field reads/writes. Enables natural syntax like rot.y = rot.y + speed * dt.

## Summary of Changes

Implemented as `lunatic.ref(e, component_name)` returning a userdata proxy with `__index`/`__newindex` metamethods for direct field access. API name changed from `gammo` to `lunatic` during development.
