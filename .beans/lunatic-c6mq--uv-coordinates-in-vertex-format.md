---
# lunatic-c6mq
title: UV coordinates in vertex format
status: todo
type: task
priority: normal
created_at: 2026-04-04T16:24:30Z
updated_at: 2026-04-04T16:24:36Z
parent: lunatic-8uei
blocked_by:
    - lunatic-rd2h
---

Extend Vertex with u/v fields. Update pipeline vertex attributes (location 2). Update vertex shader to pass UVs to fragment. Update geometry generators to emit UVs (cube: per-face 0-1, sphere: from theta/phi).
