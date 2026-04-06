#version 450

// Lens flare ghosts: screen-space ghost reflections + halo ring.
// Based on John Chapman's pseudo lens flare technique.
// Input: bloom mip (thresholded bright features).

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D bright_tex;

layout(set = 3, binding = 0) uniform FlareParams {
    vec4 params;   // .x = ghost_dispersal, .y = halo_width, .z = chroma_distortion, .w = intensity
    vec4 params2;  // (reserved)
} flare;

const int NUM_GHOSTS = 8;

// Per-ghost color tints — simulate thin-film coating on lens elements
const vec3 GHOST_TINTS[NUM_GHOSTS] = vec3[](
    vec3(1.0, 0.8, 0.4),   // warm gold
    vec3(0.6, 0.8, 1.0),   // cool blue
    vec3(0.8, 1.0, 0.7),   // pale green
    vec3(1.0, 0.6, 0.9),   // magenta
    vec3(0.5, 0.7, 1.0),   // steel blue
    vec3(1.0, 0.9, 0.6),   // amber
    vec3(0.7, 1.0, 1.0),   // cyan
    vec3(0.9, 0.7, 1.0)    // lavender
);

// Sample with per-ghost chromatic aberration and brightness clamping
vec3 sampleChromatic(vec2 uv, vec2 dir, float distortion) {
    vec3 s = vec3(
        texture(bright_tex, uv + dir * distortion).r,
        texture(bright_tex, uv).g,
        texture(bright_tex, uv - dir * distortion).b
    );
    // Prevent extremely bright sources from overwhelming the effect
    return s / (1.0 + dot(s, vec3(0.333)));
}

void main() {
    float ghost_dispersal = flare.params.x;
    float halo_width      = flare.params.y;
    float chroma_dist     = flare.params.z;
    float intensity       = flare.params.w;

    // Flip UV through screen center — ghosts are reflections
    vec2 flipped = vec2(1.0) - frag_uv;
    vec2 ghost_vec = (vec2(0.5) - flipped) * ghost_dispersal;

    vec3 result = vec3(0.0);

    // --- Ghost reflections ---
    for (int i = 0; i < NUM_GHOSTS; i++) {
        vec2 sample_uv = fract(flipped + ghost_vec * float(i));

        // Distance-from-center falloff — wider for inner ghosts, tighter for outer
        float d = distance(sample_uv, vec2(0.5));
        float falloff_exp = 10.0 + float(i) * 2.0;
        float weight = pow(1.0 - clamp(d * 2.0, 0.0, 1.0), falloff_exp);

        // Alternating size: even ghosts are slightly dimmer/smaller
        weight *= (i % 2 == 0) ? 1.0 : 0.6;

        // Chromatic direction: toward screen center
        vec2 chroma_dir = normalize(vec2(0.5) - sample_uv);

        // Scale chromatic distortion per ghost (outer ghosts get more)
        float ghost_chroma = chroma_dist * (1.0 + float(i) * 0.3);

        result += sampleChromatic(sample_uv, chroma_dir, ghost_chroma) * weight * GHOST_TINTS[i];
    }

    // --- Halo ring (circular aperture reflection) ---
    vec2 halo_vec = normalize(ghost_vec) * halo_width;
    vec2 halo_uv = flipped + halo_vec;
    float halo_d = distance(halo_uv, vec2(0.5));
    float halo_weight = 1.0 - smoothstep(0.0, 0.05, halo_d);
    halo_weight *= 0.3;
    vec2 halo_dir = normalize(vec2(0.5) - halo_uv);
    result += sampleChromatic(halo_uv, halo_dir, chroma_dist) * halo_weight;

    out_color = vec4(result * intensity, 1.0);
}
