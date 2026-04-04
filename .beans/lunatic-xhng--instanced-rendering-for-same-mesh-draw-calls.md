---
# lunatic-xhng
title: Instanced rendering for same-mesh draw calls
status: todo
type: feature
created_at: 2026-04-03T17:34:40Z
updated_at: 2026-04-03T17:34:40Z
---

Pack per-instance MVP matrices into a storage buffer and use instanced drawing (DrawGPUPrimitives with instance count > 1). Reduces draw calls from O(entities) to O(unique meshes). Requires shader modification to read instance_id and a per-frame storage buffer upload.
