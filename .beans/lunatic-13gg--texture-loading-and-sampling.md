---
# lunatic-13gg
title: Texture loading and sampling
status: completed
type: task
priority: normal
created_at: 2026-04-04T16:24:30Z
updated_at: 2026-04-04T16:37:49Z
parent: lunatic-8uei
blocked_by:
    - lunatic-c6mq
---

Texture registry on Engine (parallel to mesh/material). stb_image for decoding. SDL_GPU texture creation + upload. Sampler creation. Fragment shader gets sampler2D. MaterialData gets optional texture handle. Lua API: create_texture().

## Summary of Changes

Added texture support:
- TextureData struct + registry (64 slots) on Engine
- stb_image vendored for image decoding
- createTextureFromFile(path) and createTextureFromMemory(pixels, w, h)
- Default sampler (linear filter, repeat wrap)
- MaterialData extended with optional texture_id
- MaterialUniforms extended with has_texture flag
- Fragment shader samples base_color_tex when has_texture.x > 0.5
- Renderer binds texture+sampler per material
- Proper cleanup: textures + sampler released in deinit
