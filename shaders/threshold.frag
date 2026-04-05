#version 450

// Extract bright regions from HDR scene for bloom.

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D hdr_scene;

layout(set = 3, binding = 0) uniform BloomParams {
    vec4 params; // .x = threshold, .y = soft_knee, .z = intensity (unused here)
} bloom;

void main() {
    vec3 color = texture(hdr_scene, frag_uv).rgb;

    // Luminance-based thresholding with soft knee for smoother falloff
    float brightness = dot(color, vec3(0.2126, 0.7152, 0.0722));
    float threshold = bloom.params.x;
    float knee = bloom.params.y;

    // Soft threshold: quadratic falloff in [threshold - knee, threshold + knee]
    float soft = brightness - threshold + knee;
    soft = clamp(soft, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee + 0.00001);

    float contribution = max(soft, brightness - threshold);
    contribution /= max(brightness, 0.00001);

    out_color = vec4(color * contribution, 1.0);
}
