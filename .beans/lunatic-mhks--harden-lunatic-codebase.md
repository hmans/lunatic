---
# lunatic-mhks
title: Harden lunatic codebase
status: completed
type: task
priority: normal
created_at: 2026-04-04T10:29:18Z
updated_at: 2026-04-04T10:31:43Z
---

Fix 13 issues from adversarial code review: entity validation, ref proxy safety, depth texture resize, resource leaks, query hash ordering, rotation.z, system error handling, fog uniforms, dead code, component macro types, checknumber, player tag

## Summary of Changes

All 13 issues from the adversarial review have been fixed:

1. Entity validation via registry.valid() in entityFromLua
2. Ref proxy stale-entity checks in __index/__newindex
3. Dynamic depth texture resize in renderSystem
4. Window made resizable with SDL_WINDOW_RESIZABLE
5. uploadVertexData resource leak cleanup on all failure paths
6. Query hash order-independence via sorted entries
7. Rotation.z now applied in render (rotateZ added to math3d)
8. Failing Lua systems auto-disabled after first error
9. Fog uniforms restructured with clear field semantics
10. Dead callLua function removed
11. Component macro handles f32 and u32 field types
12. luaL_checknumber replaces luaL_optnumber (no silent defaults)
13. Player tag simplified to use lua_name directly + tag path in luaAdd
