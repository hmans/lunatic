#version 450

// ============================================================================
// Hierarchical-Z Downsample Shader — Lunatic Engine
// ============================================================================
//
// Builds a HiZ (hierarchical depth) mip chain for GPU-driven occlusion culling.
// Each mip level stores the MAXIMUM linear depth from the 2x2 texels of the
// level above, creating a conservative depth pyramid.
//
// Why max (not min)?
//   We store linear camera distance where larger = farther. The HiZ test asks:
//   "is this entity behind everything in this screen region?" An entity is
//   occluded when its nearest depth > max depth in the HiZ region. By storing
//   the maximum (farthest) depth per region, we ensure the test is conservative:
//   the entity must be behind even the farthest geometry to be culled.
//
// Two modes controlled by params.z:
//   - First pass (params.z > 0.5): reads from HDR texture alpha channel (linear
//     depth written by default.frag as frag_dist = length(world_pos - cam_pos))
//   - Subsequent passes (params.z <= 0.5): reads from previous HiZ mip level
//     (R32_FLOAT, red channel)
//
// Uses 4 NEAREST taps with max-reduce (not bilinear — averaging depth is wrong).
// Tap offsets are at ±0.25 texels, which with a 2:1 reduction hits the center
// of each of the 4 source texels exactly.
//
// Pipeline position: [previous frame's HDR alpha] → hiz_mip[0] → ... → hiz_mip[N]
// ============================================================================

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out float out_depth;

layout(set = 2, binding = 0) uniform sampler2D source_tex;

layout(set = 3, binding = 0) uniform HizParams {
    vec4 params; // .xy = texel size of source, .z = is_first_pass (read alpha), .w = unused
};

void main() {
    vec2 uv = frag_uv;
    vec2 t = params.xy; // One source texel in UV space

    // 4 NEAREST taps covering the 2x2 source region this output texel represents.
    // Offsets of ±0.25 * texel_size place each tap at the center of one source texel.
    float d0, d1, d2, d3;

    if (params.z > 0.5) {
        // First pass: read linear depth from HDR texture's alpha channel
        d0 = texture(source_tex, uv + vec2(-0.25, -0.25) * t).a;
        d1 = texture(source_tex, uv + vec2( 0.25, -0.25) * t).a;
        d2 = texture(source_tex, uv + vec2(-0.25,  0.25) * t).a;
        d3 = texture(source_tex, uv + vec2( 0.25,  0.25) * t).a;
    } else {
        // Subsequent passes: read from previous HiZ mip (R32_FLOAT, red channel)
        d0 = texture(source_tex, uv + vec2(-0.25, -0.25) * t).r;
        d1 = texture(source_tex, uv + vec2( 0.25, -0.25) * t).r;
        d2 = texture(source_tex, uv + vec2(-0.25,  0.25) * t).r;
        d3 = texture(source_tex, uv + vec2( 0.25,  0.25) * t).r;
    }

    // Max-reduce: store the farthest depth in this region
    out_depth = max(max(d0, d1), max(d2, d3));
}
