---
# lunatic-7uqt
title: Lua query API and system registration
status: completed
type: feature
priority: normal
created_at: 2026-04-04T08:56:27Z
updated_at: 2026-04-08T14:15:56Z
---

Add gammo.query(...) that returns matching entity IDs as a Lua table. Add gammo.system(name, fn) for registering Lua systems. Engine calls registered systems each frame. Remove hardcoded init/update convention.

## Summary of Changes

Implemented as `lunatic.query()`, `lunatic.each()`, `lunatic.create_query()`, `lunatic.each_query()`, and `lunatic.system()` in `lua_api.zig`. API name changed from `gammo` to `lunatic` during development.
