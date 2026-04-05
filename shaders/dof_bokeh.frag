#version 450

// Bokeh gather pass — golden angle disk sampling at half resolution.
// Scatter-as-you-gather: each sample contributes based on whether its
// own CoC disc reaches the current pixel.

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D prefiltered; // .rgb = color, .a = CoC

layout(set = 3, binding = 0) uniform BokehParams {
    vec4 params; // .xy = texel size (half res), .z = max blur radius (half-res pixels)
} bokeh;

const float GOLDEN_ANGLE = 2.39996323;
const int SAMPLES = 48;

void main() {
    vec2 texel = bokeh.params.xy;
    float maxRadius = bokeh.params.z;

    vec4 center = texture(prefiltered, frag_uv);
    float centerCoC = center.a;
    float radius = abs(centerCoC) * maxRadius;

    // Skip gather if blur radius is negligible
    if (radius < 0.5) {
        out_color = center;
        return;
    }

    vec3 accumColor = vec3(0.0);
    float accumWeight = 0.0;

    for (int i = 0; i < SAMPLES; i++) {
        float t = float(i) / float(SAMPLES);
        float angle = t * GOLDEN_ANGLE * float(SAMPLES);
        float r = sqrt(t) * radius; // sqrt for uniform disk distribution

        vec2 offset = vec2(cos(angle), sin(angle)) * r * texel;
        vec4 s = texture(prefiltered, frag_uv + offset);
        float sampleCoC = s.a;
        float sampleRadius = abs(sampleCoC) * maxRadius;

        // Scatter-as-you-gather: sample contributes if its CoC reaches us.
        // Background samples (positive CoC) are clamped to not bleed onto
        // foreground (negative CoC) — but foreground can bleed onto background.
        float effectiveRadius = sampleRadius;
        if (sampleCoC > 0.0 && centerCoC < 0.0) {
            effectiveRadius = min(effectiveRadius, radius);
        }

        float weight = smoothstep(0.0, 2.0, effectiveRadius - r + 2.0);
        accumColor += s.rgb * weight;
        accumWeight += weight;
    }

    vec3 result = accumColor / max(accumWeight, 0.001);
    out_color = vec4(result, centerCoC);
}
