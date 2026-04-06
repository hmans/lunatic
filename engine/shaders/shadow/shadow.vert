#version 450

// ============================================================================
// Shadow Map Vertex Shader — Lunatic Engine
// ============================================================================
//
// Minimal vertex shader for the shadow depth pass. Only transforms positions
// to light clip space — no normals, UVs, or lighting needed since we only
// care about depth.
//
// The MVP matrix is pre-multiplied on the CPU as: light_VP * model_matrix,
// where light_VP is the cascade's orthographic projection * light view matrix.
//
// This shader is used once per cascade (4 passes total) to fill the 2x2
// shadow atlas. Each cascade renders to its own viewport within the atlas.
// ============================================================================

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;   // unused — must match vertex layout
layout(location = 2) in vec2 in_uv;       // unused — must match vertex layout
layout(location = 3) in vec4 in_tangent;  // unused — must match vertex layout

struct InstanceData {
    mat4 mvp;    // light_VP * model (pre-multiplied on CPU)
    mat4 model;  // unused in shadow pass
    vec4 flags;  // unused in shadow pass
};

layout(std430, set = 0, binding = 0) readonly buffer InstanceBuffer {
    InstanceData instances[];
};

void main() {
    gl_Position = instances[gl_InstanceIndex].mvp * vec4(in_position, 1.0);
}
