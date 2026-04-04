---
# lunatic-n17k
title: Component vtable + query simplification + renderer decomposition
status: completed
type: task
created_at: 2026-04-04T19:50:37Z
updated_at: 2026-04-04T19:50:37Z
---

Design document for five interconnected refactorings: component metadata/vtable (eliminates 7 inline-for loops in lua_api.zig), asset handle crystallization, query cache elimination, and renderer decomposition. See docs/design-component-vtable-and-renderer-decomposition.md
