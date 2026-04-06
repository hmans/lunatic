#version 450

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec2 in_uv;
layout(location = 3) in vec4 in_tangent;

struct InstanceData {
    mat4 mvp;
    mat4 model;
    vec4 flags;
};

layout(std430, set = 0, binding = 0) readonly buffer InstanceBuffer {
    InstanceData instances[];
};

void main() {
    // MVP is pre-multiplied as light_vp * model on the CPU
    gl_Position = instances[gl_InstanceIndex].mvp * vec4(in_position, 1.0);
}
