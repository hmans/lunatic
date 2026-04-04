---
# lunatic-666x
title: PBR Cook-Torrance BRDF shader
status: completed
type: task
priority: normal
created_at: 2026-04-04T16:52:04Z
updated_at: 2026-04-04T16:55:41Z
parent: lunatic-8rb3
blocked_by:
    - lunatic-3lth
---

Replace half-Lambert with proper PBR: Cook-Torrance specular (GGX distribution, Smith geometry, Fresnel-Schlick) + Lambertian diffuse. Use metallic to blend between dielectric and metallic. Use roughness for specular distribution. Needs camera position (already in scene uniforms).

## Summary of Changes

Replaced half-Lambert with Cook-Torrance PBR:
- GGX normal distribution
- Smith-Schlick geometry function
- Fresnel-Schlick approximation
- Metallic/roughness workflow (metallic blends F0, kills diffuse)
- Metallic-roughness texture sampling (glTF convention: G=roughness, B=metallic)
- Reinhard tone mapping + gamma correction
- Occlusion modulates ambient only
- Emissive additive after lighting
