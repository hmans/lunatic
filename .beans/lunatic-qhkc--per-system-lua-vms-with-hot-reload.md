---
# lunatic-qhkc
title: Per-system Lua VMs with hot-reload
status: in-progress
type: feature
priority: normal
created_at: 2026-04-08T17:00:05Z
updated_at: 2026-04-08T17:05:17Z
---

Individual ECS systems can be implemented as standalone .lua files, each in its own LuaJIT VM. Enables hot-reload and parallel execution via flecs scheduler.

## Tasks

- [x] Restore LuaJIT in build system (build.zig, lua.zig, lua_error_helper.c)
- [x] Implement lua_systems.zig core (VM management, term bridge, flecs callback)
- [x] Wire into engine.zig (field, addLuaSystem, hot-reload, deinit)
- [x] Write example Lua system and test
- [x] Add hot-reload (mtime polling)
- [ ] Update docs
