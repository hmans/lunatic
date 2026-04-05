#version 450

// Separable Gaussian blur — use for both horizontal and vertical passes.

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D source_tex;

layout(set = 3, binding = 0) uniform BlurParams {
    vec4 direction; // .xy = blur direction (1/w,0) or (0,1/h)
} blur;

void main() {
    // 9-tap Gaussian weights (sigma ~= 4)
    const float weights[5] = float[](0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216);

    vec2 tex_offset = blur.direction.xy;
    vec3 result = texture(source_tex, frag_uv).rgb * weights[0];

    for (int i = 1; i < 5; i++) {
        result += texture(source_tex, frag_uv + tex_offset * float(i)).rgb * weights[i];
        result += texture(source_tex, frag_uv - tex_offset * float(i)).rgb * weights[i];
    }

    out_color = vec4(result, 1.0);
}
