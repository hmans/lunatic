#version 450

// ============================================================================
// Lens Flare Ghost Shader — Lunatic Engine
// ============================================================================
//
// Screen-space pseudo lens flare based on John Chapman's technique.
// Simulates the internal reflections and diffractions that occur when bright
// light bounces between lens elements in a real camera.
//
// Input: a bloom mip texture containing thresholded bright features.
// Output: a texture of ghost reflections + halo ring, added to the scene
// in the composite shader before tonemapping.
//
// Two effects are computed:
//
// 1. Ghost reflections (8 ghosts):
//    Bright features are reflected through the screen center at varying
//    distances (controlled by ghost_dispersal). Each ghost gets:
//    - A unique color tint (simulating thin-film coating on lens elements)
//    - Chromatic aberration (outer ghosts get more, like real optics)
//    - Distance-based falloff (ghosts fade toward screen edges)
//    - Alternating brightness (even/odd ghosts differ, like real multi-element lenses)
//
// 2. Halo ring:
//    A bright ring at a fixed distance from the center, simulating the
//    circular aperture reflection. Much subtler than the ghosts (0.3x weight).
//
// All sampling uses Reinhard-style brightness clamping to prevent extremely
// bright sources from overwhelming the effect with flat white.
//
// Tunable parameters (from FlareParams uniform):
//   ghost_dispersal:  Spacing between ghost images (higher = more spread)
//   halo_width:       Distance of the halo ring from center
//   chroma_distortion: Strength of per-ghost chromatic aberration
//   intensity:         Global brightness multiplier
// ============================================================================

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D bright_tex;  // Bloom mip with bright features

layout(set = 3, binding = 0) uniform FlareParams {
    vec4 params;   // .x = ghost_dispersal, .y = halo_width, .z = chroma_distortion, .w = intensity
    vec4 params2;  // (reserved for future use)
} flare;

const int NUM_GHOSTS = 8;

// Per-ghost color tints simulate the spectral shifts from thin-film coatings
// on real lens elements. Each lens surface reflects a slightly different color.
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

// Sample the bright texture with per-channel chromatic offset (R and B displaced
// in opposite directions along `dir`). The Reinhard denominator (1 / (1 + luma))
// prevents extremely bright sources from saturating to white.
vec3 sampleChromatic(vec2 uv, vec2 dir, float distortion) {
    vec3 s = vec3(
        texture(bright_tex, uv + dir * distortion).r,
        texture(bright_tex, uv).g,
        texture(bright_tex, uv - dir * distortion).b
    );
    return s / (1.0 + dot(s, vec3(0.2126, 0.7152, 0.0722)));  // Rec. 709 luminance
}

void main() {
    float ghost_dispersal = flare.params.x;
    float halo_width      = flare.params.y;
    float chroma_dist     = flare.params.z;
    float intensity       = flare.params.w;

    // Flip UV through screen center: ghost reflections are always on the
    // opposite side of the screen from the bright source.
    vec2 flipped = vec2(1.0) - frag_uv;

    // Direction and spacing for ghost placement
    vec2 ghost_vec = (vec2(0.5) - flipped) * ghost_dispersal;

    vec3 result = vec3(0.0);

    // --- Ghost reflections ---
    for (int i = 0; i < NUM_GHOSTS; i++) {
        // Each ghost is placed at increasing distances along ghost_vec.
        // fract() wraps the UV so ghosts that go off-screen reappear on the other side.
        vec2 sample_uv = fract(flipped + ghost_vec * float(i));

        // Radial falloff: ghosts are brightest at screen center, fade at edges.
        // The exponent increases per ghost, making outer ghosts more tightly focused.
        float d = distance(sample_uv, vec2(0.5));
        float falloff_exp = 10.0 + float(i) * 2.0;
        float weight = pow(1.0 - clamp(d * 2.0, 0.0, 1.0), falloff_exp);

        // Odd-numbered ghosts are dimmer (simulates varying reflectivity
        // of different lens element surfaces)
        weight *= (i % 2 == 0) ? 1.0 : 0.6;

        // Chromatic aberration direction: always toward screen center
        vec2 chroma_dir = normalize(vec2(0.5) - sample_uv);

        // Outer ghosts get stronger chromatic separation (like real optics
        // where light passes through more glass at steeper angles)
        float ghost_chroma = chroma_dist * (1.0 + float(i) * 0.3);

        result += sampleChromatic(sample_uv, chroma_dir, ghost_chroma) * weight * GHOST_TINTS[i];
    }

    // --- Halo ring (circular aperture reflection) ---
    // A subtle bright ring at a fixed distance from the flipped source position.
    // Guard against zero-length ghost_vec (source exactly at screen center)
    // to prevent NaN from normalize().
    vec2 halo_vec = length(ghost_vec) > 0.001 ? normalize(ghost_vec) * halo_width : vec2(0.0);
    vec2 halo_uv = flipped + halo_vec;
    float halo_d = distance(halo_uv, vec2(0.5));
    float halo_weight = 1.0 - smoothstep(0.0, 0.05, halo_d);  // Very tight ring
    halo_weight *= 0.3;  // Subtle — halo should be understated
    vec2 halo_dir = normalize(vec2(0.5) - halo_uv);
    result += sampleChromatic(halo_uv, halo_dir, chroma_dist) * halo_weight;

    out_color = vec4(result * intensity, 1.0);
}
