---
# lunatic-7uqt
title: Lua query API and system registration
status: in-progress
type: feature
created_at: 2026-04-04T08:56:27Z
updated_at: 2026-04-04T08:56:27Z
---

Add gammo.query(...) that returns matching entity IDs as a Lua table. Add gammo.system(name, fn) for registering Lua systems. Engine calls registered systems each frame. Remove hardcoded init/update convention.
