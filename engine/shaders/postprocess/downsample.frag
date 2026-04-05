#version 450

// 13-tap downsample (Jimenez, SIGGRAPH 2014)
// Anti-aliased downsample that eliminates shimmering artifacts.
// On the first pass (mip 0), applies Karis average to suppress fireflies.

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D source_tex;

layout(set = 3, binding = 0) uniform DownsampleParams {
    vec4 params; // .xy = texel size, .z = is_first_pass (1.0 = apply Karis)
} downsample;

float karisWeight(vec3 c) {
    float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
    return 1.0 / (1.0 + luma);
}

void main() {
    vec2 uv = frag_uv;
    vec2 t = downsample.params.xy;
    bool karis = downsample.params.z > 0.5;

    // 13 bilinear taps covering a 4x4 texel region
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
        // Karis average: weight each group by inverse luminance to suppress fireflies
        // 5 groups: center, corners, cardinals, inner quad TL, inner quad BR
        vec3 g0 = (a + b + d + e) * 0.25;
        vec3 g1 = (b + c + e + f) * 0.25;
        vec3 g2 = (d + e + g + h) * 0.25;
        vec3 g3 = (e + f + h + i) * 0.25;
        vec3 g4 = (j + k + l + m) * 0.25;

        float w0 = karisWeight(g0);
        float w1 = karisWeight(g1);
        float w2 = karisWeight(g2);
        float w3 = karisWeight(g3);
        float w4 = karisWeight(g4);

        color = (g0 * w0 + g1 * w1 + g2 * w2 + g3 * w3 + g4 * w4)
              / (w0 + w1 + w2 + w3 + w4);
    } else {
        // Standard weighted downsample
        color  = e * 0.125;                     // center
        color += (a + c + g + i) * 0.03125;     // corners
        color += (b + d + f + h) * 0.0625;      // cardinals
        color += (j + k + l + m) * 0.125;       // inner diamond
    }

    out_color = vec4(color, 1.0);
}
