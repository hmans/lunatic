#version 450

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec2 in_uv;
layout(location = 3) in vec4 in_tangent;

// Per-instance data from storage buffer
struct InstanceData {
    mat4 mvp;
    mat4 model;
};

layout(std430, set = 0, binding = 0) readonly buffer InstanceBuffer {
    InstanceData instances[];
};

layout(location = 0) out vec3 world_pos;
layout(location = 1) out vec3 world_normal;
layout(location = 2) out vec2 frag_uv;
layout(location = 3) out vec3 world_tangent;
layout(location = 4) out vec3 world_bitangent;

void main() {
    InstanceData inst = instances[gl_InstanceIndex];

    gl_Position = inst.mvp * vec4(in_position, 1.0);
    world_pos = (inst.model * vec4(in_position, 1.0)).xyz;

    vec3 N = normalize((inst.model * vec4(in_normal, 0.0)).xyz);
    vec3 T = normalize((inst.model * vec4(in_tangent.xyz, 0.0)).xyz);
    vec3 B = cross(N, T) * in_tangent.w;

    world_normal = N;
    world_tangent = T;
    world_bitangent = B;
    frag_uv = in_uv;
}
