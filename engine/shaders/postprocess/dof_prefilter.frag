#version 450

// ============================================================================
// Depth of Field — Prefilter (Half-Res Downsample) — Lunatic Engine
// ============================================================================
//
// Downsamples the HDR scene to half resolution for the bokeh gather pass.
// Running the expensive gather at half res is critical for performance —
// the bokeh shader uses 48 texture fetches per fragment.
//
// Two things happen here:
//
// 1. Color downsample with brightness weighting:
//    Like Karis averaging in bloom, this weights each tap by inverse brightness
//    to prevent a single HDR hotspot from bleeding across the downsampled image.
//
// 2. CoC propagation:
//    The CoC value is sampled from the full-res CoC texture and the maximum
//    absolute value of the 4 taps is kept. This ensures the bokeh gather pass
//    sees the correct blur extent — using the average would shrink the blur
//    disk of bright out-of-focus objects.
//
// Output: .rgb = downsampled HDR color, .a = CoC (signed, from CoC pass)
//
// Pipeline position: HDR scene + CoC -> [this shader] -> bokeh gather
// ============================================================================

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D hdr_scene;  // Full-res HDR scene
layout(set = 2, binding = 1) uniform sampler2D coc_tex;    // Full-res CoC (red channel)

layout(set = 3, binding = 0) uniform PrefilterParams {
    vec4 params;  // .xy = texel size of source (full res)
} prefilter;

// Inverse brightness weight: dim down the contribution of hot pixels
// to prevent them from dominating the downsampled result.
float brightnessWeight(vec3 c) {
    return 1.0 / (1.0 + max(c.r, max(c.g, c.b)));
}

void main() {
    vec2 t = prefilter.params.xy;

    // 4-tap bilinear downsample at half-texel offsets (centered between source texels)
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

    // CoC: keep the tap with the largest absolute CoC to preserve blur extent.
    // If we averaged, small in-focus objects surrounded by out-of-focus areas
    // would have their blur radius artificially reduced.
    float c0 = texture(coc_tex, frag_uv + t * vec2(-0.5, -0.5)).r;
    float c1 = texture(coc_tex, frag_uv + t * vec2( 0.5, -0.5)).r;
    float c2 = texture(coc_tex, frag_uv + t * vec2(-0.5,  0.5)).r;
    float c3 = texture(coc_tex, frag_uv + t * vec2( 0.5,  0.5)).r;

    float coc = c0;
    if (abs(c1) > abs(coc)) coc = c1;
    if (abs(c2) > abs(coc)) coc = c2;
    if (abs(c3) > abs(coc)) coc = c3;

    out_color = vec4(color, coc);
}
