#version 450

// Compute Circle of Confusion from linear depth stored in HDR alpha.
// Output: signed CoC in red channel (-1 = max near blur, +1 = max far blur).

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D hdr_scene; // .a = linear depth

layout(set = 3, binding = 0) uniform DofParams {
    vec4 params; // .x = focus_distance, .y = focus_range, .z = max_blur_radius (pixels)
} dof;

void main() {
    float depth = texture(hdr_scene, frag_uv).a;
    float focus_dist = dof.params.x;
    float focus_range = dof.params.y;

    // Signed CoC: negative = near field, positive = far field
    float coc = (depth - focus_dist) / max(focus_range, 0.001);
    coc = clamp(coc, -1.0, 1.0);

    out_color = vec4(coc, 0.0, 0.0, 0.0);
}
