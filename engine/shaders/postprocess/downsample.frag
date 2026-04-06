#version 450

// ============================================================================
// Bloom Downsample Shader — Lunatic Engine
// ============================================================================
//
// Progressive mip-chain downsample using 13 bilinear taps covering a 4x4 texel
// region. This is the Jimenez method from "Next Generation Post Processing in
// Call of Duty: Advanced Warfare" (SIGGRAPH 2014).
//
// Why 13 taps instead of a simple 2x2 box filter?
//   A box filter causes shimmer/aliasing because it undersamples high-frequency
//   detail. The 13-tap kernel acts like a wide tent filter that smoothly blends
//   the source, producing stable bloom without temporal flickering.
//
// On the first downsample pass (mip 0, reading from the HDR scene), Karis
// averaging is applied: each sample group is weighted by inverse luminance.
// This suppresses fireflies — a single extremely bright pixel won't dominate
// the bloom for the entire screen. Subsequent mip levels skip this because
// the fireflies have already been tamed.
//
// Pipeline position: Scene HDR -> [this shader x6 mip levels] -> upsample chain
// ============================================================================

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D source_tex;

layout(set = 3, binding = 0) uniform DownsampleParams {
    vec4 params;  // .xy = texel size of source, .z = is_first_pass (1.0 = apply Karis)
} downsample;

// Karis weight: inverse luminance weighting to suppress bright outliers.
// Bright pixels get LOW weight, dim pixels get HIGH weight.
float karisWeight(vec3 c) {
    float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));  // Rec. 709 luminance
    return 1.0 / (1.0 + luma);
}

void main() {
    vec2 uv = frag_uv;
    vec2 t = downsample.params.xy;  // One texel in UV space
    bool karis = downsample.params.z > 0.5;

    // 13 bilinear taps arranged in a cross + diamond pattern:
    //
    //   a . b . c       (a,b,c,d,e,f,g,h,i at 2-texel spacing)
    //   . j . k .       (j,k,l,m at 1-texel spacing — inner diamond)
    //   d . e . f
    //   . l . m .
    //   g . h . i
    //
    // Each tap uses hardware bilinear filtering, so we effectively sample
    // a 6x6 texel footprint from just 13 texture fetches.

    vec3 a = texture(source_tex, uv + t * vec2(-2, -2)).rgb;
    vec3 b = texture(source_tex, uv + t * vec2( 0, -2)).rgb;
    vec3 c = texture(source_tex, uv + t * vec2( 2, -2)).rgb;
    vec3 d = texture(source_tex, uv + t * vec2(-2,  0)).rgb;
    vec3 e = texture(source_tex, uv).rgb;
    vec3 f = texture(source_tex, uv + t * vec2( 2,  0)).rgb;
    vec3 g = texture(source_tex, uv + t * vec2(-2,  2)).rgb;
    vec3 h = texture(source_tex, uv + t * vec2( 0,  2)).rgb;
    vec3 i = texture(source_tex, uv + t * vec2( 2,  2)).rgb;
    vec3 j = texture(source_tex, uv + t * vec2(-1, -1)).rgb;
    vec3 k = texture(source_tex, uv + t * vec2( 1, -1)).rgb;
    vec3 l = texture(source_tex, uv + t * vec2(-1,  1)).rgb;
    vec3 m = texture(source_tex, uv + t * vec2( 1,  1)).rgb;

    vec3 color;

    if (karis) {
        // Karis average: split the 13 taps into 5 overlapping 2x2 groups,
        // average each group, then blend the groups weighted by inverse luminance.
        // This ensures no single bright pixel can dominate the result.
        vec3 g0 = (a + b + d + e) * 0.25;  // top-left quad
        vec3 g1 = (b + c + e + f) * 0.25;  // top-right quad
        vec3 g2 = (d + e + g + h) * 0.25;  // bottom-left quad
        vec3 g3 = (e + f + h + i) * 0.25;  // bottom-right quad
        vec3 g4 = (j + k + l + m) * 0.25;  // center diamond

        float w0 = karisWeight(g0);
        float w1 = karisWeight(g1);
        float w2 = karisWeight(g2);
        float w3 = karisWeight(g3);
        float w4 = karisWeight(g4);

        color = (g0 * w0 + g1 * w1 + g2 * w2 + g3 * w3 + g4 * w4)
              / (w0 + w1 + w2 + w3 + w4);
    } else {
        // Standard weighted downsample (non-first passes).
        // Weights are chosen to match a 6x6 tent filter:
        //   center (e):          4/32 = 0.125
        //   corners (a,c,g,i):   1/32 = 0.03125 each
        //   cardinals (b,d,f,h): 2/32 = 0.0625 each
        //   inner (j,k,l,m):     4/32 = 0.125 each (these overlap center)
        color  = e * 0.125;
        color += (a + c + g + i) * 0.03125;
        color += (b + d + f + h) * 0.0625;
        color += (j + k + l + m) * 0.125;
    }

    out_color = vec4(color, 1.0);
}
