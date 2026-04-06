---
# lunatic-y0d3
title: Fix cascaded shadow maps
status: completed
type: bug
priority: normal
created_at: 2026-04-06T10:45:20Z
updated_at: 2026-04-06T11:23:47Z
---

Shadows were added in the WIP commit but aren't visually working. Multiple issues identified: potential binding mismatches, wrong sampler, possible ortho/depth issues, no PCF.


## Summary of Changes

Fixed cascaded shadow maps that were completely broken in the WIP commit:

- **Metal Y-flip**: Shadow atlas sampling needed Y-flip (`(-sc.y) * 0.5 + 0.5`) because Metal render targets have inverted Y vs clip space for non-swapchain textures
- **Shadow pipeline**: Reverted CULLMODE_FRONT → CULLMODE_NONE (front-face culling breaks thin geometry like the floor cube)
- **PCF**: Added 4-tap percentage-closer filtering for softer shadow edges
- **Normal-offset bias**: Pushes sample point along surface normal to reduce self-shadowing on grazing surfaces
- **Cascade tuning**: Reduced lambda (0.7→0.5) and shadow far (200→80) for better cascade distribution across the visible scene
- **Shadow sampler**: Changed from linear/repeat to nearest/clamp for correct depth comparison
- **Depth bias**: Increased from 0.002 to 0.005
