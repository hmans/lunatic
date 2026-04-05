#version 450

// Downsample HDR scene to half resolution for DoF processing.
// Uses 4-tap bilinear with brightness weighting to suppress fireflies.
// Packs CoC from the CoC texture alongside the color.

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D hdr_scene;
layout(set = 2, binding = 1) uniform sampler2D coc_tex;

layout(set = 3, binding = 0) uniform PrefilterParams {
    vec4 params; // .xy = texel size of source (full res)
} prefilter;

float brightnessWeight(vec3 c) {
    return 1.0 / (1.0 + max(c.r, max(c.g, c.b)));
}

void main() {
    vec2 t = prefilter.params.xy;

    // 4-tap bilinear downsample with brightness weighting
    vec3 s0 = texture(hdr_scene, frag_uv + t * vec2(-0.5, -0.5)).rgb;
    vec3 s1 = texture(hdr_scene, frag_uv + t * vec2( 0.5, -0.5)).rgb;
    vec3 s2 = texture(hdr_scene, frag_uv + t * vec2(-0.5,  0.5)).rgb;
    vec3 s3 = texture(hdr_scene, frag_uv + t * vec2( 0.5,  0.5)).rgb;

    float w0 = brightnessWeight(s0);
    float w1 = brightnessWeight(s1);
    float w2 = brightnessWeight(s2);
    float w3 = brightnessWeight(s3);
    float wsum = w0 + w1 + w2 + w3;

    vec3 color = (s0 * w0 + s1 * w1 + s2 * w2 + s3 * w3) / wsum;

    // Sample CoC — use max absolute CoC of the 4 taps to preserve blur extent
    float c0 = texture(coc_tex, frag_uv + t * vec2(-0.5, -0.5)).r;
    float c1 = texture(coc_tex, frag_uv + t * vec2( 0.5, -0.5)).r;
    float c2 = texture(coc_tex, frag_uv + t * vec2(-0.5,  0.5)).r;
    float c3 = texture(coc_tex, frag_uv + t * vec2( 0.5,  0.5)).r;

    // For far field, take max; for near field, take min (most negative)
    float coc = c0;
    if (abs(c1) > abs(coc)) coc = c1;
    if (abs(c2) > abs(coc)) coc = c2;
    if (abs(c3) > abs(coc)) coc = c3;

    out_color = vec4(color, coc);
}
