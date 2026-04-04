---
# lunatic-ljv1
title: Component proxy refs with metatables
status: in-progress
type: feature
created_at: 2026-04-04T09:17:04Z
updated_at: 2026-04-04T09:17:04Z
---

Add gammo.ref(e, component_name) that returns a Lua userdata proxy with __index/__newindex metamethods dispatching to Zig ECS field reads/writes. Enables natural syntax like rot.y = rot.y + speed * dt.
