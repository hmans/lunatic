---
# gammo-nuts
title: Cross-platform shaders via HLSL + SDL_shadercross
status: todo
type: task
created_at: 2026-04-03T17:41:06Z
updated_at: 2026-04-03T17:41:06Z
---

Move shaders from inline MSL strings to HLSL source files. Use SDL_shadercross (or equivalent) to cross-compile to SPIR-V (Vulkan), MSL (Metal), and DXBC/DXIL (D3D12) at build time. Load the correct format at runtime based on SDL_GetGPUShaderFormats(). This unblocks Linux and Windows support.
