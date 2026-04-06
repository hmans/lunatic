---
# lunatic-y0d3
title: Fix cascaded shadow maps
status: in-progress
type: bug
created_at: 2026-04-06T10:45:20Z
updated_at: 2026-04-06T10:45:20Z
---

Shadows were added in the WIP commit but aren't visually working. Multiple issues identified: potential binding mismatches, wrong sampler, possible ortho/depth issues, no PCF.
