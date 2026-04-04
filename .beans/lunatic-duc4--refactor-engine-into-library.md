---
# lunatic-duc4
title: Refactor engine into library
status: completed
type: feature
priority: normal
created_at: 2026-04-04T12:23:34Z
updated_at: 2026-04-04T12:33:46Z
---

Move all global state into Engine struct, expose as importable Zig module. Engine.init/deinit/loadScript/run API. Lua callbacks get engine pointer via upvalues. Headless mode for testing.

## Summary of Changes

Moved all global state into Engine struct. Lua callbacks get engine pointer via upvalues (lua_pushcclosure). Engine.init takes *Engine for pointer stability. Headless mode for testing.
