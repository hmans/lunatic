---
# lunatic-sevr
title: Add unit and integration tests
status: completed
type: task
priority: normal
created_at: 2026-04-04T11:47:30Z
updated_at: 2026-04-04T11:58:33Z
---

Tier 1: math3d unit tests. Tier 2: headless Lua integration tests. Requires extracting Lua API init from GPU init in main.zig.

## Summary of Changes

- 14 unit tests for math3d.zig (Vec3 + Mat4 operations)
- 20 integration tests in tests.zig (entity lifecycle, component CRUD, ref proxies, queries, systems, settings API)
- Extracted initLuaApi/initRegistry/deinitRegistry/resetSystems from main.zig for headless testing
- build.zig test step runs both math and integration tests via zig build test
