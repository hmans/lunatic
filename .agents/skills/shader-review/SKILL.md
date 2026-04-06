---
name: shader-review
description: >
  This skill should be used when the user asks to "review shaders", "audit shaders",
  "check shader quality", "optimize shaders", "review GLSL", "shader best practices",
  or wants a thorough analysis of the engine's or game's shader code against
  state-of-the-art real-time rendering practices.
---

# Shader Review

Perform a thorough review of GLSL shader code in the Lunatic engine (and any game-specific shaders),
evaluating correctness, performance, visual quality, and adherence to modern real-time rendering practices.

## When to Use

- The user requests a shader review, audit, or optimization pass
- New shaders have been added or existing shaders significantly modified
- The user asks about shader best practices or SOTA techniques

## Shader Locations

- **Scene shaders**: `engine/shaders/scene/` (default.vert, default.frag)
- **Shadow shaders**: `engine/shaders/shadow/` (shadow.vert, shadow.frag)
- **Post-processing shaders**: `engine/shaders/postprocess/` (bloom, DoF, composite, lens flare, etc.)
- **Game shaders**: Any `.vert`/`.frag` files outside `engine/` added by the game project

## Review Process

### 1. Gather Context

Read all shader files using Glob (`engine/shaders/**/*.{vert,frag}`) and any game-specific shaders.
Also read relevant engine-side setup in `renderer.zig` and `postprocess.zig` to understand
uniform layouts, texture bindings, and pipeline configuration.

### 2. Research SOTA Practices

Use WebSearch to look up current best practices for each technique found in the shaders.
Suggested queries (adapt based on what the shaders actually implement):

- `"PBR GLSL best practices 2025"` for physically-based rendering
- `"GGX specular anti-aliasing real-time"` for specular highlights
- `"cascaded shadow maps filtering techniques"` for shadow quality
- `"physically based bloom real-time rendering"` for bloom
- `"bokeh depth of field GPU"` for DoF
- `"ACES tonemap improvements filmic"` for tonemapping
- `"clustered forward shading GPU optimization"` for light culling
- `"normal map blending techniques"` for tangent-space normal mapping
- `"PCF shadow filtering quality"` for shadow softness
- `"chromatic aberration film grain shader"` for post-FX realism
- `"GLSL shader performance mobile desktop"` for general optimization

Focus searches on techniques actually present in the codebase. Skip irrelevant topics.

### 3. Evaluate Each Shader

For every shader file, assess the following dimensions:

#### Correctness

- Precision qualifiers (mediump/highp usage where it matters)
- Correct coordinate spaces (world vs view vs clip)
- Proper normalization of vectors after interpolation
- Shadow bias and acne prevention
- Depth linearization accuracy
- sRGB vs linear color space handling

#### Performance

- Unnecessary dependent texture reads
- Redundant calculations that could move to the vertex shader
- Branch coherence (avoid divergent branches in fragment shaders)
- Texture sampling efficiency (LOD hints, gather operations)
- Register pressure from excessive temporaries
- Opportunities for MAD (multiply-add) fusion
- Per-fragment work that could be per-vertex or per-tile

#### Visual Quality

- PBR energy conservation
- Specular aliasing mitigation
- Shadow filtering quality (PCF kernel, Poisson disk, PCSS)
- Bloom thresholding (soft knee vs hard threshold)
- Tonemapping curve accuracy and highlight rolloff
- DoF bokeh shape and edge quality
- Fog integration with lighting

#### Robustness

- Division by zero guards
- NaN/Inf propagation prevention
- Clamping of values that could go out of range
- Handling of edge cases (zero-length normals, degenerate tangents)

#### Cross-Platform

- Metal Y-flip correctness for render-to-texture sampling
- SPIRV-Cross compatibility concerns
- Vulkan vs Metal behavioral differences

### 4. Produce the Report

Structure findings as:

```
## Shader Review Report

### Summary
Brief overall assessment — what's solid, what needs attention.

### Critical Issues
Issues that cause visual artifacts or incorrect rendering.

### Performance Opportunities
Optimizations ranked by expected impact.

### Quality Improvements
SOTA techniques that could improve visual fidelity.

### Minor / Style
Naming, comments, consistency.

### Per-Shader Notes
Detailed notes for each shader file reviewed.
```

For each finding, include:

- **File and line** reference
- **What** the issue is
- **Why** it matters (with SOTA reference where applicable)
- **Suggested fix** (concrete code snippet when possible)

### 5. Prioritize Recommendations

Rank all recommendations by impact-to-effort ratio. Group into:

- **Quick wins**: High impact, low effort (e.g., adding a missing clamp, fixing a bias)
- **Medium effort**: Meaningful improvement, moderate refactoring (e.g., upgrading PCF to PCSS)
- **Major work**: Significant technique upgrades (e.g., switching tonemapping curves, adding screen-space reflections)

## Engine-Specific Gotchas

Refer to the project's CLAUDE.md for critical details:

- **Metal Y-flip**: Shadow atlas and any render-to-texture must flip Y on Metal
- **HDR alpha = linear depth**: Fragment shaders must write linear depth to alpha for DoF
- **sRGB round-trip**: Clear/fog colors are inverse-ACES-transformed in `renderer.zig`
- **Specular clamp**: Output clamped to 64.0 to prevent fireflies
- **PostProcess ping-pong**: DoF writes to `hdr_texture_b` then swaps; be aware of read/write hazards
- **SPIRV-Cross cache**: Shader cache may be stale after edits — `rm -rf .zig-cache` if behavior is unexpected
