---
# lunatic-dtea
title: GLTF parser and loader
status: in-progress
type: task
priority: normal
created_at: 2026-04-04T16:24:30Z
updated_at: 2026-04-04T16:38:02Z
parent: lunatic-8uei
blocked_by:
    - lunatic-13gg
---

Add cgltf as a C dependency. New gltf.zig module that parses a .gltf/.glb file and creates mesh + material + texture resources via Engine APIs. Lua API: load_gltf(path) returning a table of mesh/material handles.
