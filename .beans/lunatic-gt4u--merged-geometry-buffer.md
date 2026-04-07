---
# lunatic-gt4u
title: Merged Geometry Buffer
status: completed
type: feature
priority: normal
created_at: 2026-04-07T15:31:29Z
updated_at: 2026-04-07T15:36:06Z
---

## Tasks

- [x] Add merged vertex/index buffer fields and constants to Engine
- [x] Add base_vertex/first_index offsets to MeshData
- [x] Modify createMesh to append to merged buffers
- [x] Create merged buffers at engine init
- [x] Update submitDrawCalls to bind merged buffers once
- [x] Update submitShadowDrawCalls to bind merged buffers once
- [x] Cleanup: release merged buffers, handle destroyMesh
- [x] Verify examples still work

## Summary of Changes

All mesh vertex/index data now lives in two shared GPU buffers instead of individual per-mesh allocations.

- MeshData stores base_vertex/first_index offsets instead of GPU buffer pointers
- createMesh appends to merged VB/IB via uploadToBufferRegion helper
- submitDrawCalls/submitShadowDrawCalls bind merged buffers once per pass, use offsets in draw calls
- Merged VB: 1M vertices (48MB), merged IB: 4M indices (16MB) — preallocated
- destroyMesh just frees the registry slot (data stays in merged buffer)
