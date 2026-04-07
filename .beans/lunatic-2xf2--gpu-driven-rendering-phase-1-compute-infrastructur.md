---
# lunatic-2xf2
title: 'GPU-Driven Rendering: Phase 1 — Compute Infrastructure + GPU Instance Setup'
status: completed
type: feature
priority: normal
created_at: 2026-04-07T15:15:09Z
updated_at: 2026-04-07T15:23:05Z
---

## Tasks

- [x] Add compute shader stage to build system (build.zig)
- [x] Create compute shader for instance data preparation (instance_setup.comp)
- [x] Add compute pipeline creation helper in renderer
- [x] Create entity data buffer + GPU infrastructure
- [x] Replace CPU uploadInstances() with compute dispatch
- [x] Update shadow pass to use compute dispatch
- [x] Verify examples still work correctly

## Design

**Current flow:** CPU queries ECS → sorts by mesh+material → computes model/MVP matrices → uploads to GPU via transfer buffer → renders

**New flow:** CPU queries ECS → sorts → uploads raw entity data (pos/rot/scale/flags) → GPU compute shader computes model+MVP → renders

The compute shader replaces the matrix math in `uploadInstances()` and `executeShadowPass()`, moving ~16K matrix multiplications per frame to the GPU.

### Buffer changes
- **Entity data buffer** (new): raw per-entity transform data, `COMPUTE_STORAGE_READ`
- **Instance buffer** (existing): changes to `GRAPHICS_STORAGE_READ | COMPUTE_STORAGE_WRITE`
- **Entity transfer buffer** (new): CPU→GPU upload of entity data

## Summary of Changes

Added GPU compute shader infrastructure to the engine and moved per-instance matrix computation from CPU to GPU:

- **build.zig**: Added `.compute` shader stage, compute-specific spirv-cross flags (no `--msl-decoration-binding` for correct Metal buffer ordering)
- **instance_setup.comp**: New compute shader that reads raw entity transforms, builds model matrices, multiplies by VP, writes InstanceData — handles both scene and shadow passes
- **renderer.zig**: Added `createComputePipeline()`, `initComputePipeline()`, `uploadEntityData()`, `dispatchInstanceSetup()`, `dispatchInstanceData()`; shadow pass now uses compute dispatch
- **engine.zig**: Added compute pipeline + entity data buffer fields, creation, cleanup; frame loop uploads entity data once then dispatches compute per shadow cascade + scene pass

Instance setup time dropped from ~0.16ms (CPU) to ~0.01ms (GPU compute). Entity data is uploaded once per frame and reused across all 5 dispatches (4 shadow cascades + 1 scene).
