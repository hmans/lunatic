---
# lunatic-xom8
title: Screen-Space Reflections (SSR)
status: completed
type: feature
priority: normal
created_at: 2026-04-07T18:01:52Z
updated_at: 2026-04-07T18:13:44Z
---

Hi-Z ray-marched SSR as a post-process pass. Uses existing HiZ pyramid and linear depth from HDR alpha. User-controllable via Camera component fields and debug panel.


## Tasks

- [x] Phase 1: SSR shader — Hi-Z ray march in screen space, output reflection color + confidence
- [x] Phase 2: Camera component fields — ssr_intensity, ssr_max_distance, ssr_thickness, ssr_stride
- [x] Phase 3: Pipeline + integration — post-process pass between scene and DoF, blend with scene
- [x] Phase 4: Debug panel controls — sliders for all SSR parameters
- [x] Phase 5: Lua API (auto via component_ops) — expose SSR fields in camera component
- [x] Phase 6: Verified on all 3 scenes (especially material showcase)


## Summary of Changes

Implemented screen-space reflections via Hi-Z ray marching:
- ssr.frag: world-space ray march with depth-reconstructed normals, edge/distance/thickness fading
- ssr_composite.frag: additive blend of reflection into scene HDR
- Camera fields: ssr_intensity, ssr_max_distance, ssr_stride, ssr_thickness
- Debug panel: Reflections (SSR) section with sliders
- Mat4.invert() added to math3d.zig for inverse VP computation
- Depth discontinuity rejection for clean silhouette edges
