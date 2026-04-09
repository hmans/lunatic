---
# lunatic-a4lh
title: Upgrade shadow PCF to 16-tap rotated Poisson disk
status: scrapped
type: task
priority: normal
created_at: 2026-04-09T11:11:38Z
updated_at: 2026-04-09T13:47:26Z
---

Major visual improvement to shadow edge quality

## Reasons for Scrapping

Multiple attempts to upgrade to 16-tap Poisson disk PCF caused shadow rendering to break entirely on Metal/SPIRV-Cross. Root cause unclear — possibly related to const arrays, mat2 rotation, or clamp with tile bounds in the SPIRV-Cross Metal codegen path. Reverted to original 4-tap PCF. Needs investigation with SPIRV-Cross output inspection before reattempting.
