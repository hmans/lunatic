---
# lunatic-uf9g
title: Indirect Draw with GPU Compaction
status: completed
type: feature
priority: normal
created_at: 2026-04-07T15:44:49Z
updated_at: 2026-04-07T15:54:48Z
---

## Tasks

- [x] Add BatchInfo + IndirectDrawCommand structs
- [x] Add batch info + indirect draw buffers to Engine
- [x] Compute batch boundaries from sorted draw list
- [x] Upload batch info + initial indirect commands (num_instances=0)
- [x] Update compute shader: atomicAdd for compaction, write indirect commands
- [x] Update compute pipeline (2 readonly + 2 readwrite buffers)
- [x] Add submitDrawCallsIndirect using SDL_DrawGPUIndexedPrimitivesIndirect
- [x] Wire into frame loop (scene pass only, shadow keeps existing path)
- [x] Verify rendering correctness

## Design

**Scene pass flow:**
1. CPU: sorted draw list → compute batch boundaries (batch_id per entity)
2. CPU: upload entity data (with batch_id in rotation.w), batch offsets, indirect commands (num_instances=0)
3. GPU compute: frustum cull → atomicAdd on indirect_commands[batch_id].num_instances → write instance to batch region
4. CPU: for each batch, bind material → SDL_DrawGPUIndexedPrimitivesIndirect

**Shadow passes:** unchanged (keep zeroed-MVP approach, no compaction)

## Summary of Changes

Scene pass now uses GPU-driven indirect draw with compaction. The compute shader atomically increments per-batch instance counts, compacts visible entities into contiguous regions, and the CPU issues SDL_DrawGPUIndexedPrimitivesIndirect per material batch.

- BatchInfo/IndirectDrawCommand structs, batch_info_buffer + indirect_draw_buffer
- computeBatches: CPU extracts batch boundaries from sorted draw list
- uploadBatchData: uploads batch offsets + initial indirect commands (num_instances=0)
- Compute shader: atomicAdd on indirect_commands[batch_id].num_instances for visible entities
- submitDrawCallsIndirect: iterates batches, binds material, indirect draw
- Key fix: indirect buffer must NOT cycle in compute pass (needs uploaded initial data)
- MSL buffer ordering: forced by controlling first-access order in GLSL source
