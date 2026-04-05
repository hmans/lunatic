#version 450

// Lens flare ghosts: screen-space ghost reflections + halo ring.
// Based on John Chapman's pseudo lens flare technique.
// Input: bloom mip[0] (thresholded bright features at half resolution).

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D bright_tex;

layout(set = 3, binding = 0) uniform FlareParams {
    vec4 params;   // .x = ghost_dispersal, .y = halo_width, .z = chroma_distortion, .w = intensity
    vec4 params2;  // .x = starburst_intensity, .y = camera_angle_z
} flare;

const int NUM_GHOSTS = 4;
const float NUM_RAYS = 12.0; // starburst ray count

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

        // Distance-from-center falloff (ghosts near edges fade)
        float d = distance(sample_uv, vec2(0.5));
        float weight = pow(1.0 - clamp(d * 2.0, 0.0, 1.0), 20.0);

        // Chromatic direction: toward screen center
        vec2 chroma_dir = normalize(vec2(0.5) - sample_uv);

        result += sampleChromatic(sample_uv, chroma_dir, chroma_dist) * weight;
    }

    // --- Halo ring (circular aperture reflection) ---
    // Sample at halo_width distance from center, weighted by a thin ring falloff
    vec2 halo_vec = normalize(ghost_vec) * halo_width;
    vec2 halo_uv = flipped + halo_vec;
    float halo_d = distance(halo_uv, vec2(0.5));
    // Ring-shaped weight: peaks when halo_d ≈ 0, sharp falloff
    float halo_weight = 1.0 - smoothstep(0.0, 0.05, halo_d);
    halo_weight *= 0.3; // halo is accent, not dominant
    vec2 halo_dir = normalize(vec2(0.5) - halo_uv);
    result += sampleChromatic(halo_uv, halo_dir, chroma_dist) * halo_weight;

    // --- Starburst (procedural radial star pattern, rotates with camera) ---
    float starburst_intensity = flare.params2.x;
    if (starburst_intensity > 0.0) {
        float cam_angle = flare.params2.y;
        vec2 to_center = frag_uv - vec2(0.5);
        float angle = atan(to_center.y, to_center.x) + cam_angle;
        // Multi-frequency star: sharp primary + softer secondary
        float star = pow(abs(cos(angle * NUM_RAYS)), 8.0) * 0.7
                   + pow(abs(cos(angle * NUM_RAYS * 0.5 + 0.5)), 4.0) * 0.3;
        // Blend between full starburst and no modulation
        result *= mix(1.0, star, starburst_intensity);
    }

    out_color = vec4(result * intensity, 1.0);
}
