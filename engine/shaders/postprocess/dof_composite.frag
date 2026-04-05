#version 450

// Composite DoF: blend half-res blurred result with full-res sharp image
// using per-pixel CoC. Output replaces the HDR scene texture.

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D hdr_scene;   // sharp, full res
layout(set = 2, binding = 1) uniform sampler2D dof_blurred;  // bokeh result, half res
layout(set = 2, binding = 2) uniform sampler2D coc_tex;      // full-res CoC

void main() {
    vec4 sharp = texture(hdr_scene, frag_uv);
    vec3 blurred = texture(dof_blurred, frag_uv).rgb;
    float coc = abs(texture(coc_tex, frag_uv).r);

    // Smooth blend: fully sharp at coc=0, fully blurred at coc>=1
    float blend = smoothstep(0.0, 1.0, coc * 2.0);
    vec3 color = mix(sharp.rgb, blurred, blend);

    // Preserve the original alpha (linear depth) for downstream passes
    out_color = vec4(color, sharp.a);
}
