#version 450

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;

layout(set = 1, binding = 0) uniform VertexUniforms {
    mat4 mvp;
    mat4 model;
} u;

layout(location = 0) out vec3 world_pos;
layout(location = 1) out vec3 world_normal;

void main() {
    gl_Position = u.mvp * vec4(in_position, 1.0);
    world_pos = (u.model * vec4(in_position, 1.0)).xyz;
    world_normal = normalize((u.model * vec4(in_normal, 0.0)).xyz);
}
