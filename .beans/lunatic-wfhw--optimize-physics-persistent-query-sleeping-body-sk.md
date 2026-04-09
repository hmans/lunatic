---
# lunatic-wfhw
title: 'Optimize physics: persistent query + sleeping body skip'
status: completed
type: task
priority: normal
created_at: 2026-04-09T10:31:09Z
updated_at: 2026-04-09T10:32:13Z
---

Make syncCurrentTransforms use a persistent query instead of recreating each frame. Skip sleeping bodies in transform sync.

## Summary

Persistent query for transform sync (created once at init, reused every step). Skip sleeping bodies via isActive() check.
