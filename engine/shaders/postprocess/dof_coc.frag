#version 450

// ============================================================================
// Depth of Field — Circle of Confusion (CoC) — Lunatic Engine
// ============================================================================
//
// Computes the Circle of Confusion for each pixel from the linear depth
// stored in the HDR scene texture's alpha channel.
//
// The CoC represents how blurry a pixel should be based on its distance
// from the camera's focus plane:
//   - CoC = 0:  In focus (at focus_distance)
//   - CoC > 0:  Far field (behind focus — background blur)
//   - CoC < 0:  Near field (in front of focus — foreground blur)
//
// Output: signed CoC in [-1, 1] range, stored in the red channel.
// The magnitude represents blur amount (0 = sharp, 1 = maximum blur).
// The sign distinguishes near vs far field, which matters for the bokeh
// gather pass (foreground can bleed onto background, but not vice versa).
//
// Pipeline position: HDR scene -> [this shader] -> prefilter -> bokeh -> composite
// ============================================================================

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D hdr_scene;  // .a = linear depth (world units)

layout(set = 3, binding = 0) uniform DofParams {
    vec4 params;  // .x = focus_distance, .y = focus_range, .z = max_blur_radius (pixels)
} dof;

void main() {
    float depth = texture(hdr_scene, frag_uv).a;  // Linear depth from scene shader
    float focus_dist = dof.params.x;   // Distance to the focus plane (world units)
    float focus_range = dof.params.y;  // Width of the in-focus zone (world units)

    // Signed CoC: linear ramp from the focus plane.
    // Objects at focus_dist +/- focus_range/2 are fully in focus (CoC near 0).
    // Objects at focus_dist +/- focus_range are at maximum blur (CoC = +/-1).
    float coc = (depth - focus_dist) / max(focus_range, 0.001);  // Avoid div-by-zero
    coc = clamp(coc, -1.0, 1.0);

    out_color = vec4(coc, 0.0, 0.0, 0.0);
}
