#version 450

layout(location = 0) in vec3 world_pos;
layout(location = 1) in vec3 world_normal;
layout(location = 2) in vec2 frag_uv;

layout(set = 3, binding = 0) uniform SceneUniforms {
    vec4 light_dir;
    vec4 camera_pos;
    vec4 fog_color;   // .xyz = color, .w = fog_enabled (1.0 or 0.0)
    vec4 fog_params;  // .x = fog_start, .y = fog_end
    vec4 ambient;
} scene;

layout(set = 3, binding = 1) uniform MaterialUniforms {
    vec4 albedo;
} mat;

layout(location = 0) out vec4 out_color;

void main() {
    vec3 N = normalize(world_normal);
    vec3 L = normalize(scene.light_dir.xyz);
    float ndotl = dot(N, L);
    float diffuse = ndotl * 0.5 + 0.5;
    diffuse = diffuse * diffuse;

    vec3 color = mat.albedo.xyz * (scene.ambient.xyz + diffuse);

    if (scene.fog_color.w > 0.5) {
        float dist = length(world_pos - scene.camera_pos.xyz);
        float fog_start = scene.fog_params.x;
        float fog_end = scene.fog_params.y;
        float fog_factor = clamp((dist - fog_start) / (fog_end - fog_start), 0.0, 1.0);
        color = mix(color, scene.fog_color.xyz, fog_factor);
    }

    out_color = vec4(color, 1.0);
}
