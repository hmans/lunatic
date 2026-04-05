#version 450

// Final composite: blend bloom into HDR scene, then tone map + gamma correct.

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D hdr_scene;
layout(set = 2, binding = 1) uniform sampler2D bloom_tex;

layout(set = 3, binding = 0) uniform CompositeParams {
    vec4 params;  // .x = bloom_intensity, .y = exposure
    vec4 params2; // .x = vignette_intensity, .y = vignette_smoothness
} composite;

void main() {
    vec3 hdr = texture(hdr_scene, frag_uv).rgb;
    vec3 bloom = texture(bloom_tex, frag_uv).rgb;

    vec3 color = hdr + bloom * composite.params.x;

    // Exposure
    color *= composite.params.y;

    // ACES-ish tone mapping (more filmic than Reinhard)
    // Attempt using the simple Narkowicz approximation
    color = clamp((color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14), 0.0, 1.0);

    // Gamma correction
    color = pow(color, vec3(1.0 / 2.2));

    // Vignette — darken edges based on distance from center
    float vignette_intensity = composite.params2.x;
    if (vignette_intensity > 0.0) {
        float smoothness = composite.params2.y;
        vec2 uv_centered = frag_uv - 0.5;
        float dist = length(uv_centered);
        float vignette = smoothstep(smoothness, smoothness - 0.35, dist);
        color *= mix(1.0, vignette, vignette_intensity);
    }

    out_color = vec4(color, 1.0);
}
