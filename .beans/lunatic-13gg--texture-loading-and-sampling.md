---
# lunatic-13gg
title: Texture loading and sampling
status: todo
type: task
priority: normal
created_at: 2026-04-04T16:24:30Z
updated_at: 2026-04-04T16:24:36Z
parent: lunatic-8uei
blocked_by:
    - lunatic-c6mq
---

Texture registry on Engine (parallel to mesh/material). stb_image for decoding. SDL_GPU texture creation + upload. Sampler creation. Fragment shader gets sampler2D. MaterialData gets optional texture handle. Lua API: create_texture().
