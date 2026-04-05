---
# lunatic-0wvx
title: Depth of field post-processing
status: completed
type: feature
priority: normal
created_at: 2026-04-05T13:33:53Z
updated_at: 2026-04-05T13:40:00Z
---

5-pass gather-based DoF: CoC from depth, prefilter downsample, golden angle bokeh gather, tent post-filter, composite. Inserted before bloom in pipeline.

## Summary of Changes

- 4 new shaders: dof_coc.frag, dof_prefilter.frag, dof_bokeh.frag, dof_composite.frag
- Golden angle disk sampling (22 taps) with scatter-as-you-gather weighting
- Linear depth stored in HDR alpha channel (no separate depth resolve needed)
- Brightness-weighted prefilter downsample to suppress HDR fireflies
- HDR texture ping-pong (hdr_texture_b) to avoid read-write hazard during composite
- Camera component gets dof_focus_dist, dof_focus_range, dof_blur_radius fields
- Pipeline order: scene → DoF → bloom → composite+tonemap
- Debug UI with Focus Distance, Focus Range, Blur Radius sliders
- dof_focus_dist=0 disables DoF (just passes through)
