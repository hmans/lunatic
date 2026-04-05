---
# lunatic-hct2
title: Integrate Dear ImGui with dcimgui + SDL3 GPU backend
status: completed
type: feature
priority: normal
created_at: 2026-04-05T12:13:07Z
updated_at: 2026-04-05T12:25:04Z
---

Vendor ImGui source + dcimgui C bindings + SDL3/SDL_GPU backends. Wire into engine frame loop as LDR overlay after bloom composite.

## Summary of Changes

- Vendored Dear ImGui v1.92.7 + dcimgui C bindings + SDL3/SDL_GPU backends into vendor/imgui/
- Wrote cimgui_impl_sdlgpu3.h/.cpp — thin C wrapper around the C++ backend functions
- Wired ImGui C++ compilation into build.zig (9 source files, c++17)
- Merged cimgui.h into engine's @cImport block (shared types with SDL3)
- ImGui lifecycle in engine.zig: CreateContext, InitForSDLGPU, Init, NewFrame/Render/EndFrame
- ImGui renders as LDR overlay after bloom composite, directly to swapchain
- zig_primitives example has a debug UI with bloom parameter sliders
