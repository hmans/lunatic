#version 450

// ============================================================================
// Scene Vertex Shader — Lunatic Engine
// ============================================================================
//
// Transforms vertices from object space to clip space and prepares world-space
// vectors for the fragment shader's PBR lighting calculations.
//
// Uses instanced rendering: per-instance transforms (MVP, model matrix, flags)
// are stored in a GPU storage buffer rather than per-draw uniforms, enabling
// the engine to batch many objects into a single draw call.
//
// Outputs to fragment shader:
//   - world_pos:       Fragment position in world space (for lighting, fog, depth)
//   - world_normal:    Interpolated normal in world space (for diffuse/specular)
//   - frag_uv:         Texture coordinates (passed through unchanged)
//   - world_tangent:   Tangent vector in world space (for normal mapping TBN matrix)
//   - world_bitangent: Bitangent in world space (cross(N, T) * handedness)
//   - receives_shadow: Per-instance flag (1.0 = sample shadow map, 0.0 = skip)
// ============================================================================

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec2 in_uv;
layout(location = 3) in vec4 in_tangent;  // .xyz = tangent direction, .w = handedness (+1 or -1)

// Per-instance data packed into a storage buffer (one entry per draw instance).
// The engine writes this buffer each frame after sorting and batching draws.
struct InstanceData {
    mat4 mvp;    // Pre-multiplied: projection * view * model
    mat4 model;  // Model-to-world transform (used for lighting in world space)
    vec4 flags;  // .x = receives_shadow (1.0 or 0.0)
};

layout(std430, set = 0, binding = 0) readonly buffer InstanceBuffer {
    InstanceData instances[];
};

layout(location = 0) out vec3 world_pos;
layout(location = 1) out vec3 world_normal;
layout(location = 2) out vec2 frag_uv;
layout(location = 3) out vec3 world_tangent;
layout(location = 4) out vec3 world_bitangent;
layout(location = 5) flat out float receives_shadow;  // flat = no interpolation (it's a flag)

void main() {
    InstanceData inst = instances[gl_InstanceIndex];

    gl_Position = inst.mvp * vec4(in_position, 1.0);
    world_pos = (inst.model * vec4(in_position, 1.0)).xyz;

    // Transform normal and tangent to world space.
    // Using vec4(..., 0.0) ignores translation — we only want rotation+scale.
    // Note: for non-uniform scale, the normal should use the inverse-transpose
    // of the model matrix. Currently the engine assumes uniform scale.
    vec3 N = normalize((inst.model * vec4(in_normal, 0.0)).xyz);
    vec3 T = normalize((inst.model * vec4(in_tangent.xyz, 0.0)).xyz);

    // Bitangent is perpendicular to both N and T. The handedness factor
    // (in_tangent.w) accounts for mirrored UVs in the mesh data.
    vec3 B = cross(N, T) * in_tangent.w;

    world_normal = N;
    world_tangent = T;
    world_bitangent = B;
    frag_uv = in_uv;
    receives_shadow = inst.flags.x;
}
