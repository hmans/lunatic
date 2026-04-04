---
# lunatic-rd2h
title: Index buffer support
status: completed
type: task
priority: normal
created_at: 2026-04-04T16:24:30Z
updated_at: 2026-04-04T16:27:53Z
parent: lunatic-8uei
---

Add indexed drawing to the renderer. SDL_GPU index buffer creation, binding, and DrawGPUIndexedPrimitives. Update MeshData to store optional index buffer + count. Update geometry generators to emit indexed meshes.

## Summary of Changes

Added indexed drawing support:
- MeshData stores optional index buffer + count
- createMesh accepts optional u16 index slice
- Renderer binds index buffer and uses DrawGPUIndexedPrimitives when present
- Geometry generators return Mesh struct (vertices + indices) with shared vertices
- uploadGPUBuffer generalized from uploadVertexData
- Cube: 24 verts + 36 indices (was 36 unindexed). Sphere: grid topology with shared vertices.
