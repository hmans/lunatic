---
# lunatic-mrpc
title: Implement bloom post-processing
status: completed
type: feature
priority: normal
created_at: 2026-04-05T11:05:29Z
updated_at: 2026-04-05T11:54:16Z
---

HDR render target, brightness extraction, Gaussian blur, composite+tonemap. New postprocess.zig + 4 shaders.

## Summary of Changes

- Added HDR rendering pipeline (R16G16B16A16_FLOAT scene render target)
- New `postprocess.zig` module: threshold extraction, separable Gaussian blur, composite+tonemap
- 4 new shaders: fullscreen.vert, threshold.frag, blur.frag, composite.frag
- Moved tone mapping from default.frag to composite pass (ACES approximation replaces Reinhard)
- Scene renders to HDR texture; MSAA resolves to HDR; post-process writes to swapchain
- Frame orchestration moved from renderer to engine.run() for clean module separation
- Bloom configurable from Zig (engine.postprocess.*) and Lua (lunatic.set_bloom)
- zig_primitives example updated with emissive materials and bloom settings

## Per-Camera Post-Processing Refactor

- Bloom settings (threshold, intensity, exposure, soft_knee, blur_passes) moved to Camera component
- PostProcessState on Engine reduced to GPU handles only (no settings)
- Renderer split into prepareFrame() + renderCamera() for per-camera orchestration
- engine.run() loops over cameras: render scene → HDR, postprocess → swapchain per camera
- Lua `set_bloom(entity, threshold, intensity, exposure)` now targets a camera entity
- Component `fromLua` now uses `luaL_optnumber` — missing trailing args use struct defaults
- Bonus: all components now support partial Lua args (omitted fields use defaults)
