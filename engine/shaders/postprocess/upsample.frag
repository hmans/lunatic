#version 450

// ============================================================================
// Bloom Upsample Shader — Lunatic Engine
// ============================================================================
//
// 9-tap tent filter that upsamples the bloom from a lower (smaller) mip level
// and adds it to the current (larger) mip level via additive blending.
//
// The render target already contains this level's downsample result (loaded
// via LOADOP_LOAD). This shader's output is ADDED to it by the blend state,
// progressively accumulating the bloom from coarse to fine.
//
// Each mip level has an independent tint/weight that controls its contribution
// to the final bloom shape. Lower mips (coarser) create the wide glow, higher
// mips (finer) add detail close to bright sources. These tints are exposed to
// Lua via lunatic.get/set_bloom_tints().
//
// Pipeline position: downsample chain -> [this shader x6 levels] -> composite
// ============================================================================

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D lower_mip;  // The smaller (more blurred) mip to upsample

layout(set = 3, binding = 0) uniform UpsampleParams {
    vec4 params;  // .xy = texel size of lower_mip, .z = tint/weight for this level
} upsample;

void main() {
    vec2 uv = frag_uv;
    vec2 t = upsample.params.xy;    // One texel of the lower mip in UV space
    float tint = upsample.params.z;  // Per-level intensity weight

    // 3x3 tent filter (bilinear interpolation of a box filter).
    // Weights form a tent shape:
    //   1  2  1
    //   2  4  2   / 16
    //   1  2  1
    // This is smoother than a box filter and avoids the blockiness
    // that would be visible with nearest-neighbor upsampling.
    vec3 a = texture(lower_mip, uv + vec2(-t.x, -t.y)).rgb;
    vec3 b = texture(lower_mip, uv + vec2( 0.0, -t.y)).rgb;
    vec3 c = texture(lower_mip, uv + vec2( t.x, -t.y)).rgb;
    vec3 d = texture(lower_mip, uv + vec2(-t.x,  0.0)).rgb;
    vec3 e = texture(lower_mip, uv).rgb;
    vec3 f = texture(lower_mip, uv + vec2( t.x,  0.0)).rgb;
    vec3 g = texture(lower_mip, uv + vec2(-t.x,  t.y)).rgb;
    vec3 h = texture(lower_mip, uv + vec2( 0.0,  t.y)).rgb;
    vec3 i = texture(lower_mip, uv + vec2( t.x,  t.y)).rgb;

    vec3 upsampled = (a + c + g + i)        // corners: weight 1
                   + (b + d + f + h) * 2.0  // edges: weight 2
                   + e * 4.0;               // center: weight 4
    upsampled /= 16.0;                      // normalize (1*4 + 2*4 + 4*1 = 16)

    // Output is added to the render target by the GPU blend state (ONE, ONE).
    // The tint controls how much this mip level contributes to the final bloom.
    out_color = vec4(upsampled * tint, 1.0);
}
