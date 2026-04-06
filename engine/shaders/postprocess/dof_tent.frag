#version 450

// ============================================================================
// Depth of Field — Tent Smoothing — Lunatic Engine
// ============================================================================
//
// A simple 3x3 tent filter applied to the bokeh gather output to smooth out
// noise from the stochastic disk sampling. Without this pass, the golden-angle
// sampling can produce subtle dithering patterns, especially in regions with
// a medium CoC where the gather radius is small relative to the sample spacing.
//
// The tent kernel (1-2-1 / 2-4-2 / 1-2-1, sum=16) is applied to the full
// vec4 output, preserving the CoC in the alpha channel for the composite pass.
//
// Pipeline position: bokeh gather -> [this shader] -> DoF composite
// ============================================================================

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D source_tex;

layout(set = 3, binding = 0) uniform TentParams {
    vec4 params;  // .xy = texel size (half res, same as bokeh output)
} tent;

void main() {
    vec2 t = tent.params.xy;

    // 9 taps in a 3x3 grid with tent weights
    vec4 a = texture(source_tex, frag_uv + vec2(-t.x, -t.y));  // corners: weight 1
    vec4 b = texture(source_tex, frag_uv + vec2( 0.0, -t.y));  // edges:   weight 2
    vec4 c = texture(source_tex, frag_uv + vec2( t.x, -t.y));
    vec4 d = texture(source_tex, frag_uv + vec2(-t.x,  0.0));
    vec4 e = texture(source_tex, frag_uv);                      // center:  weight 4
    vec4 f = texture(source_tex, frag_uv + vec2( t.x,  0.0));
    vec4 g = texture(source_tex, frag_uv + vec2(-t.x,  t.y));
    vec4 h = texture(source_tex, frag_uv + vec2( 0.0,  t.y));
    vec4 i = texture(source_tex, frag_uv + vec2( t.x,  t.y));

    out_color = ((a + c + g + i) + (b + d + f + h) * 2.0 + e * 4.0) / 16.0;
}
