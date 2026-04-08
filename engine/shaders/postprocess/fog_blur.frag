#version 450

// ============================================================================
// Volumetric Fog Bilateral Blur — Lunatic Engine
// ============================================================================
//
// Smooths the integrated fog texture to remove visible froxel grid artifacts.
// The froxel volume has a coarse XY resolution (160×90) that can appear as
// blocky patterns in the final image, especially around point light halos.
//
// Uses a depth-aware bilateral filter: spatial Gaussian weighted by depth
// similarity. This smooths fog in regions of similar depth while preserving
// sharp fog-geometry boundaries (e.g., fog stops cleanly at a wall).
//
// The filter kernel spans ±4 pixels with a 5×5 sparse sample pattern (offsets
// of 0, ±2, ±4) to cover the ~8-12 pixel froxel cells at 1440p with only
// 25 taps instead of 81.
//
// Applied once after fog integration, before the final composite pass.
// ============================================================================

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_fog;

layout(set = 2, binding = 0) uniform sampler2D fog_tex;   // Integrated fog (rgb=scatter, a=transmittance)
layout(set = 2, binding = 1) uniform sampler2D scene_tex;  // HDR scene (alpha = linear depth)

layout(set = 3, binding = 0) uniform BlurParams {
    vec4 texel_size;  // x = 1/width, y = 1/height, z = unused, w = unused
};

void main() {
    float center_depth = texture(scene_tex, frag_uv).a;

    // Depth sigma: controls bilateral depth sensitivity.
    // Proportional to center depth so distant fog (larger froxels) gets
    // proportionally more blur without smearing foreground boundaries.
    float depth_sigma = max(center_depth * 0.05, 0.5);
    float inv_2sigma2 = 0.5 / (depth_sigma * depth_sigma);

    // Sparse 5×5 bilateral filter (offsets: -4, -2, 0, 2, 4 pixels)
    // Spatial Gaussian weights for sigma ≈ 3 pixels
    const int TAPS = 5;
    const float offsets[TAPS] = float[TAPS](-4.0, -2.0, 0.0, 2.0, 4.0);
    const float spatial[TAPS] = float[TAPS](0.0606, 0.2417, 0.3829, 0.2417, 0.0606);

    vec4 accum = vec4(0.0);
    float weight_sum = 0.0;

    for (int j = 0; j < TAPS; j++) {
        for (int i = 0; i < TAPS; i++) {
            vec2 offset = vec2(offsets[i] * texel_size.x, offsets[j] * texel_size.y);
            vec2 sample_uv = frag_uv + offset;

            vec4 fog_sample = texture(fog_tex, sample_uv);
            float sample_depth = texture(scene_tex, sample_uv).a;

            // Bilateral weight = spatial Gaussian × depth similarity
            float spatial_w = spatial[i] * spatial[j];
            float depth_diff = sample_depth - center_depth;
            float depth_w = exp(-depth_diff * depth_diff * inv_2sigma2);

            float w = spatial_w * depth_w;
            accum += fog_sample * w;
            weight_sum += w;
        }
    }

    out_fog = accum / max(weight_sum, 1e-6);
}
