#version 450

// ============================================================================
// Depth of Field — Bokeh Gather — Lunatic Engine
// ============================================================================
//
// The core blur pass of the DoF pipeline. For each fragment, samples nearby
// texels in a disk pattern and blends them based on their Circle of Confusion.
//
// Uses the "scatter-as-you-gather" technique: instead of scattering each bright
// pixel outward (which requires compute or geometry shaders), we gather samples
// from the neighborhood and weight them based on whether their OWN CoC disk
// would reach the current pixel. This approximates the physically correct
// scatter operation using a standard fragment shader.
//
// The gather pattern uses golden angle spacing (137.5 degrees between samples)
// with sqrt(t) radial distribution for a uniform density disk. This produces
// the characteristic circular bokeh shape without the banding artifacts of
// regular grid or ring sampling.
//
// Near/far field interaction:
//   Background samples (positive CoC) are prevented from bleeding onto
//   foreground pixels (negative CoC) — a background tree shouldn't blur
//   over a foreground character. But foreground CAN bleed onto background,
//   simulating the way out-of-focus foreground objects appear as soft overlays.
//
// Runs at half resolution for performance (71 samples * half-res = manageable).
//
// Pipeline position: prefilter -> [this shader] -> tent smooth -> composite
// ============================================================================

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D prefiltered;  // .rgb = half-res color, .a = CoC

layout(set = 3, binding = 0) uniform BokehParams {
    vec4 params;  // .xy = texel size (half res), .z = max blur radius (half-res pixels)
} bokeh;

const float GOLDEN_ANGLE = 2.39996323;  // radians (= 137.508 degrees)
const int SAMPLES = 71;                 // Total gather samples per pixel

void main() {
    vec2 texel = bokeh.params.xy;
    float maxRadius = bokeh.params.z;

    vec4 center = texture(prefiltered, frag_uv);
    float centerCoC = center.a;
    float radius = abs(centerCoC) * maxRadius;  // Blur disk radius in half-res pixels

    // Skip gather if this pixel is essentially in focus
    if (radius < 0.5) {
        out_color = center;
        return;
    }

    vec3 accumColor = vec3(0.0);
    float accumWeight = 0.0;

    for (int i = 0; i < SAMPLES; i++) {
        float t = float(i) / float(SAMPLES);

        // Golden angle spiral: each sample is 137.5 degrees from the last.
        // This fills the disk more uniformly than concentric rings.
        float angle = t * GOLDEN_ANGLE * float(SAMPLES);

        // sqrt(t) distribution: places more samples at the outer edge of the
        // disk, compensating for the larger area of outer rings. Without sqrt,
        // the center would be oversampled relative to its area.
        float r = sqrt(t) * radius;

        vec2 offset = vec2(cos(angle), sin(angle)) * r * texel;
        vec4 s = texture(prefiltered, frag_uv + offset);
        float sampleCoC = s.a;
        float sampleRadius = abs(sampleCoC) * maxRadius;

        // Scatter-as-you-gather: a sample contributes to this pixel if its
        // own CoC disk is large enough to reach here (distance r from center).
        float effectiveRadius = sampleRadius;

        // Near/far field rule: if the sample is in the far field (positive CoC)
        // but we're in the near field (negative CoC = foreground), clamp the
        // sample's effective radius so background can't bleed onto foreground.
        if (sampleCoC > 0.0 && centerCoC < 0.0) {
            effectiveRadius = min(effectiveRadius, radius);
        }

        // Smooth weight: full contribution if the sample's disk covers us,
        // fading to zero at the edge. The +2.0 offset and range provide
        // a soft transition rather than a hard cutoff.
        float weight = smoothstep(0.0, 2.0, effectiveRadius - r + 2.0);
        accumColor += s.rgb * weight;
        accumWeight += weight;
    }

    vec3 result = accumColor / max(accumWeight, 0.001);  // Avoid div-by-zero
    out_color = vec4(result, centerCoC);  // Pass CoC through for the tent filter
}
