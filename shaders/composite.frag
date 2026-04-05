#version 450

// Final composite: bloom + tonemap + gamma + post effects.

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D hdr_scene;
layout(set = 2, binding = 1) uniform sampler2D bloom_tex;

layout(set = 3, binding = 0) uniform CompositeParams {
    vec4 params;  // .x = bloom_intensity, .y = exposure
    vec4 params2; // .x = vignette_intensity, .y = vignette_smoothness
    vec4 params3; // .x = chromatic_aberration, .y = grain_intensity, .z = grain_time
    vec4 params4; // .x = color_temp (negative=cool, positive=warm)
} composite;

// Simple hash for film grain
float hash(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

void main() {
    vec2 uv = frag_uv;

    // Chromatic aberration — offset R and B channels toward screen edges
    float ca_strength = composite.params3.x;
    vec3 color;
    if (ca_strength > 0.0) {
        vec2 uv_centered = uv - 0.5;
        float dist2 = dot(uv_centered, uv_centered);
        vec2 offset = uv_centered * dist2 * ca_strength;

        float r = texture(hdr_scene, uv + offset).r;
        float g = texture(hdr_scene, uv).g;
        float b = texture(hdr_scene, uv - offset).b;
        color = vec3(r, g, b);

        // Apply CA to bloom too
        float br = texture(bloom_tex, uv + offset).r;
        float bg = texture(bloom_tex, uv).g;
        float bb = texture(bloom_tex, uv - offset).b;
        color += vec3(br, bg, bb) * composite.params.x;
    } else {
        color = texture(hdr_scene, uv).rgb;
        color += texture(bloom_tex, uv).rgb * composite.params.x;
    }

    // Exposure
    color *= composite.params.y;

    // Color temperature — shift white balance before tonemapping
    float temp = composite.params4.x;
    if (abs(temp) > 0.001) {
        // Warm: boost red, reduce blue. Cool: boost blue, reduce red.
        color *= vec3(1.0 + temp * 0.1, 1.0, 1.0 - temp * 0.1);
    }

    // ACES tone mapping (Narkowicz approximation)
    color = clamp((color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14), 0.0, 1.0);

    // Gamma correction
    color = pow(color, vec3(1.0 / 2.2));

    // Vignette
    float vignette_intensity = composite.params2.x;
    if (vignette_intensity > 0.0) {
        float smoothness = composite.params2.y;
        vec2 vc = frag_uv - 0.5;
        float dist = length(vc);
        float vignette = smoothstep(smoothness, smoothness - 0.35, dist);
        color *= mix(1.0, vignette, vignette_intensity);
    }

    // Film grain — subtle animated noise
    float grain_intensity = composite.params3.y;
    if (grain_intensity > 0.0) {
        float grain_time = composite.params3.z;
        float noise = hash(frag_uv * 1000.0 + grain_time) * 2.0 - 1.0;
        // Grain is stronger in darker areas (like real film)
        float luminance = dot(color, vec3(0.2126, 0.7152, 0.0722));
        float grain_amount = grain_intensity * (1.0 - luminance * 0.5);
        color += color * noise * grain_amount;
    }

    out_color = vec4(color, 1.0);
}
