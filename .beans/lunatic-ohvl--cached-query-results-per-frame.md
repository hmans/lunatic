---
# lunatic-ohvl
title: Cached query results per frame
status: scrapped
type: feature
priority: normal
created_at: 2026-04-04T09:23:25Z
updated_at: 2026-04-08T14:16:03Z
---

Cache gammo.query() results as Lua tables. Track dirty flags per component type, invalidate at frame start. Rebuild only when components changed since last frame. Snapshot-per-frame semantics.

## Reasons for Scrapping

The ad-hoc `lunatic.query()` builds tables on demand, and the persistent `lunatic.create_query()`/`lunatic.each_query()` API uses flecs cached queries natively. Per-frame Lua-side caching with dirty flags was not needed — flecs handles query caching internally.
