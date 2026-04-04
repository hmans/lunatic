---
# lunatic-ohvl
title: Cached query results per frame
status: in-progress
type: feature
created_at: 2026-04-04T09:23:25Z
updated_at: 2026-04-04T09:23:25Z
---

Cache gammo.query() results as Lua tables. Track dirty flags per component type, invalidate at frame start. Rebuild only when components changed since last frame. Snapshot-per-frame semantics.
