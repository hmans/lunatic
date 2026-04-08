---
# lunatic-ofci
title: Instanced rendering for draw call batching
status: completed
type: feature
priority: normal
created_at: 2026-04-05T16:13:24Z
updated_at: 2026-04-08T14:15:59Z
---

Replace per-entity draw calls with instanced rendering. SSBO holds per-instance model/MVP matrices. One draw call per mesh+material batch.

## Summary of Changes

GPU-driven instanced rendering with compute shader instance setup. Per-instance transforms uploaded to SSBO, compute shader builds model/MVP matrices, batched instanced draw calls grouped by mesh+material. Also includes HiZ occlusion culling.
