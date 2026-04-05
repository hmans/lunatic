#version 450

// 9-tap tent upsample. Output is added to the render target via additive blending
// (the render target already contains this level's downsample via LOADOP_LOAD).

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D lower_mip;

layout(set = 3, binding = 0) uniform UpsampleParams {
    vec4 params; // .xy = texel size of lower_mip, .z = tint/weight for this level
} upsample;

void main() {
    vec2 uv = frag_uv;
    vec2 t = upsample.params.xy;
    float tint = upsample.params.z;

    // 9-tap tent filter on the lower (smaller) mip
    // Weights: 1 2 1 / 2 4 2 / 1 2 1  (sum = 16)
    vec3 a = texture(lower_mip, uv + vec2(-t.x, -t.y)).rgb;
    vec3 b = texture(lower_mip, uv + vec2( 0.0, -t.y)).rgb;
    vec3 c = texture(lower_mip, uv + vec2( t.x, -t.y)).rgb;
    vec3 d = texture(lower_mip, uv + vec2(-t.x,  0.0)).rgb;
    vec3 e = texture(lower_mip, uv).rgb;
    vec3 f = texture(lower_mip, uv + vec2( t.x,  0.0)).rgb;
    vec3 g = texture(lower_mip, uv + vec2(-t.x,  t.y)).rgb;
    vec3 h = texture(lower_mip, uv + vec2( 0.0,  t.y)).rgb;
    vec3 i = texture(lower_mip, uv + vec2( t.x,  t.y)).rgb;

    vec3 upsampled = (a + c + g + i)
                   + (b + d + f + h) * 2.0
                   + e * 4.0;
    upsampled /= 16.0;

    // Output tinted upsample — additive blending adds this to the existing content
    out_color = vec4(upsampled * tint, 1.0);
}
