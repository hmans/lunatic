#version 450

// ============================================================================
// Depth of Field — Tent Smoothing — Lunatic Engine
// ============================================================================
//
// A 3x3 tent filter applied to the bokeh gather output to smooth out noise
// from the stochastic golden-angle disk sampling.
//
// The filter width scales with the local Circle of Confusion (stored in the
// bokeh output's alpha channel). At small CoC values the filter stays tight
// (standard 3x3 at single-texel spacing), but at large CoC values the offsets
// widen to cover the larger gaps between the 71 spiral samples. Without this
// adaptive scaling, extreme blur radii produce visible dotty patterns where
// individual gather samples show through.
//
// The tent kernel (1-2-1 / 2-4-2 / 1-2-1, sum=16) weights are unchanged —
// only the spacing between taps is adjusted. The CoC alpha is preserved for
// the composite pass.
//
// Pipeline position: bokeh gather -> [this shader] -> DoF composite
// ============================================================================

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D source_tex;

layout(set = 3, binding = 0) uniform TentParams {
    vec4 params;  // .xy = texel size (half res), .z = max blur radius (half-res pixels)
} tent;

void main() {
    // Read center CoC to determine how much to widen the tent filter.
    // The CoC is in [-1, 1] from the bokeh pass, and we scale by the max
    // blur radius to get the actual disk size in half-res pixels.
    vec4 e = texture(source_tex, frag_uv);
    float coc = abs(e.a);
    float disk_radius = coc * tent.params.z;

    // Scale the tent filter offsets based on the bokeh disk radius.
    // At small radii (<=3px), use 1-texel spacing (standard 3x3 tent).
    // At large radii, widen proportionally so the 9 taps span enough of
    // the disk to smooth out the sparse golden-angle sample pattern.
    // The 0.4 factor is empirical: with 71 gather samples (SAMPLES in
    // dof_bokeh.frag), the inter-sample spacing at the disk edge is roughly
    // ~2*pi*R/sqrt(71) ≈ 0.75*R pixels. A tent offset of 0.4*R covers enough
    // of the disk per tap direction to fill in the gaps without over-blurring
    // sharp in-focus areas.
    float scale = max(1.0, disk_radius * 0.4);
    vec2 t = tent.params.xy * scale;

    // 9 taps in a 3x3 grid with tent weights
    vec4 a = texture(source_tex, frag_uv + vec2(-t.x, -t.y));  // corners: weight 1
    vec4 b = texture(source_tex, frag_uv + vec2( 0.0, -t.y));  // edges:   weight 2
    vec4 c = texture(source_tex, frag_uv + vec2( t.x, -t.y));
    vec4 d = texture(source_tex, frag_uv + vec2(-t.x,  0.0));
    vec4 f = texture(source_tex, frag_uv + vec2( t.x,  0.0));
    vec4 g = texture(source_tex, frag_uv + vec2(-t.x,  t.y));
    vec4 h = texture(source_tex, frag_uv + vec2( 0.0,  t.y));
    vec4 i = texture(source_tex, frag_uv + vec2( t.x,  t.y));

    out_color = ((a + c + g + i) + (b + d + f + h) * 2.0 + e * 4.0) / 16.0;
}
