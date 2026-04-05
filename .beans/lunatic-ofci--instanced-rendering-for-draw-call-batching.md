---
# lunatic-ofci
title: Instanced rendering for draw call batching
status: in-progress
type: feature
created_at: 2026-04-05T16:13:24Z
updated_at: 2026-04-05T16:13:24Z
---

Replace per-entity draw calls with instanced rendering. SSBO holds per-instance model/MVP matrices. One draw call per mesh+material batch.
