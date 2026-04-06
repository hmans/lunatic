#version 450

// ============================================================================
// Depth of Field — Composite — Lunatic Engine
// ============================================================================
//
// Blends the half-resolution DoF blur result back with the full-resolution
// sharp image using each pixel's Circle of Confusion.
//
// The blend uses smoothstep with a 2x scale factor so the transition from
// sharp to blurred starts at small CoC values and reaches full blur by CoC=0.5.
// This makes the focus transition feel more natural — a linear blend would
// keep too much sharpness in slightly-out-of-focus areas.
//
// The original alpha channel (linear depth) is preserved for any downstream
// passes that need it.
//
// Note: this composites near and far field together using the same blend.
// A more sophisticated approach would separate near-field into its own buffer
// with alpha for proper occlusion (foreground blur over in-focus objects).
//
// Pipeline position: sharp HDR + blurred bokeh + CoC -> [this shader] -> bloom
// ============================================================================

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D hdr_scene;    // Full-res sharp image
layout(set = 2, binding = 1) uniform sampler2D dof_blurred;  // Half-res bokeh result (after tent filter)
layout(set = 2, binding = 2) uniform sampler2D coc_tex;      // Full-res CoC for per-pixel blend control

void main() {
    vec4 sharp = texture(hdr_scene, frag_uv);
    vec3 blurred = texture(dof_blurred, frag_uv).rgb;  // Upsampled via bilinear from half-res
    float coc = abs(texture(coc_tex, frag_uv).r);       // Absolute CoC (both near and far blur)

    // Smooth blend: fully sharp at coc=0, fully blurred at coc>=0.5.
    // The 2x multiplier makes the blur onset more aggressive — without it,
    // slightly out-of-focus areas would retain too much sharpness.
    float blend = smoothstep(0.0, 1.0, coc * 2.0);
    vec3 color = mix(sharp.rgb, blurred, blend);

    // Preserve original alpha (linear depth) — the bloom downsample pass
    // doesn't use it, but the composite pass needs it for any depth-aware effects.
    out_color = vec4(color, sharp.a);
}
