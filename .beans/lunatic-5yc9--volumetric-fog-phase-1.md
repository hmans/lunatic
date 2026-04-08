---
# lunatic-5yc9
title: Volumetric Fog (Phase 1)
status: completed
type: feature
priority: normal
created_at: 2026-04-08T07:47:47Z
updated_at: 2026-04-08T14:11:11Z
---

Froxel-based volumetric fog with global density, height falloff, and light scattering through shadow maps. God rays, atmospheric haze, colored light shafts.


## Tasks

- [x] Phase 1a: Froxel 3D texture — create RGBA16F volume, map to view frustum
- [x] Phase 1b: Fog injection compute shader — global density + height falloff + directional light scattering via shadow cascades
- [x] Phase 1c: Point/spot light scattering injection
- [x] Phase 1d: Integration compute shader — front-to-back march through froxels, output 2D fog texture
- [x] Phase 1e: Composite — blend fog into scene in final composite pass
- [x] Phase 1f: Camera component fields — fog_density, fog_height_falloff, fog_scattering, fog_color
- [x] Phase 1g: Debug panel controls + Lua API
- [x] Phase 1h: Verify with all example scenes

## Summary of Changes

Froxel-based volumetric fog (160x90x64 grid, exponential depth) with:
- Global density, height falloff, and anisotropic scattering
- Point/spot light injection with screen-space shadow volumes (configurable steps + softness)
- Front-to-back integration compute shader outputting 2D fog texture
- Composite into final scene pass
- Lua API via `lunatic.set_volumetric_fog()` with full parameter control
- Debug UI panel with all fog + shadow volume controls

Also improved DoF quality: 71-sample bokeh gather, adaptive tent filter, extended blur radius slider.
