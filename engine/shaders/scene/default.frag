#version 450

layout(location = 0) in vec3 world_pos;
layout(location = 1) in vec3 world_normal;
layout(location = 2) in vec2 frag_uv;
layout(location = 3) in vec3 world_tangent;
layout(location = 4) in vec3 world_bitangent;

layout(set = 3, binding = 0) uniform SceneUniforms {
    vec4 light_dir;
    vec4 camera_pos;
    vec4 fog_color;   // .xyz = color, .w = fog_enabled
    vec4 fog_params;  // .x = fog_start, .y = fog_end
    vec4 ambient;
} scene;

layout(set = 3, binding = 1) uniform MaterialUniforms {
    vec4 albedo;
    vec4 material_params;  // .x = metallic, .y = roughness
    vec4 texture_flags;    // .x = has_base_color, .y = has_mr, .z = has_normal, .w = has_emissive
    vec4 emissive;         // .xyz = emissive factor, .w = has_occlusion
} mat;

layout(set = 2, binding = 0) uniform sampler2D base_color_tex;
layout(set = 2, binding = 1) uniform sampler2D metallic_roughness_tex;
layout(set = 2, binding = 2) uniform sampler2D normal_tex;
layout(set = 2, binding = 3) uniform sampler2D emissive_tex;
layout(set = 2, binding = 4) uniform sampler2D occlusion_tex;

layout(location = 0) out vec4 out_color;

const float PI = 3.14159265359;

// GGX/Trowbridge-Reitz normal distribution
float distributionGGX(float NdotH, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float denom = NdotH * NdotH * (a2 - 1.0) + 1.0;
    return a2 / (PI * denom * denom);
}

// Smith's geometry function (Schlick-GGX)
float geometrySmith(float NdotV, float NdotL, float roughness) {
    float r = roughness + 1.0;
    float k = (r * r) / 8.0;
    float ggx1 = NdotV / (NdotV * (1.0 - k) + k);
    float ggx2 = NdotL / (NdotL * (1.0 - k) + k);
    return ggx1 * ggx2;
}

// Fresnel-Schlick approximation
vec3 fresnelSchlick(float cosTheta, vec3 F0) {
    return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

void main() {
    vec3 N = normalize(world_normal);

    // Normal mapping
    if (mat.texture_flags.z > 0.5) {
        vec3 T = normalize(world_tangent);
        vec3 B = normalize(world_bitangent);
        mat3 TBN = mat3(T, B, N);
        vec3 map_normal = texture(normal_tex, frag_uv).xyz * 2.0 - 1.0;
        N = normalize(TBN * map_normal);
    }

    vec3 V = normalize(scene.camera_pos.xyz - world_pos);
    vec3 L = normalize(scene.light_dir.xyz);
    vec3 H = normalize(V + L);

    // Material parameters
    float metallic = mat.material_params.x;
    float roughness = max(mat.material_params.y, 0.04); // clamp to avoid division by zero

    // Base color
    vec3 base_color = mat.albedo.xyz;
    if (mat.texture_flags.x > 0.5) {
        base_color *= texture(base_color_tex, frag_uv).xyz;
    }

    // Metallic/roughness texture (green = roughness, blue = metallic per glTF spec)
    if (mat.texture_flags.y > 0.5) {
        vec3 mr = texture(metallic_roughness_tex, frag_uv).xyz;
        roughness *= mr.g;
        metallic *= mr.b;
        roughness = max(roughness, 0.04);
    }

    // Specular anti-aliasing: widen roughness when the normal changes faster
    // than the pixel can resolve. Prevents sub-pixel GGX peaks from flickering.
    // (Tokuyoshi/Kaplanyan 2019, simplified)
    float sigma2 = dot(fwidth(N), vec3(0.333));
    roughness = sqrt(roughness * roughness + sigma2 * sigma2);

    // Cook-Torrance BRDF
    float NdotL = max(dot(N, L), 0.0);
    float NdotV = max(dot(N, V), 0.001);
    float NdotH = max(dot(N, H), 0.0);
    float HdotV = max(dot(H, V), 0.0);

    // Fresnel reflectance at normal incidence (dielectric = 0.04, metallic = base_color)
    vec3 F0 = mix(vec3(0.04), base_color, metallic);

    float D = distributionGGX(NdotH, roughness);
    float G = geometrySmith(NdotV, NdotL, roughness);
    vec3  F = fresnelSchlick(HdotV, F0);

    // Specular
    vec3 specular = (D * G * F) / (4.0 * NdotV * NdotL + 0.0001);

    // Diffuse (metals have no diffuse)
    vec3 kD = (1.0 - F) * (1.0 - metallic);
    vec3 diffuse = kD * base_color / PI;

    // Direct lighting
    vec3 color = (diffuse + specular) * NdotL;

    // Ambient (simple, not IBL)
    vec3 ambient_color = scene.ambient.xyz * base_color;

    // Occlusion (modulates ambient only)
    if (mat.emissive.w > 0.5) {
        float ao = texture(occlusion_tex, frag_uv).r;
        ambient_color *= ao;
    }

    color += ambient_color;

    // Emissive
    vec3 emissive_color = mat.emissive.xyz;
    if (mat.texture_flags.w > 0.5) {
        emissive_color *= texture(emissive_tex, frag_uv).xyz;
    }
    color += emissive_color;

    // Fog
    if (scene.fog_color.w > 0.5) {
        float dist = length(world_pos - scene.camera_pos.xyz);
        float fog_start = scene.fog_params.x;
        float fog_end = scene.fog_params.y;
        float fog_factor = clamp((dist - fog_start) / (fog_end - fog_start), 0.0, 1.0);
        color = mix(color, scene.fog_color.xyz, fog_factor);
    }

    // Clamp to sane HDR range. GGX specular can produce extreme single-pixel
    // values (thousands) at low roughness, causing temporal fireflies.
    // 64x overbright is more than enough for bloom while preventing outliers.
    color = min(color, vec3(64.0));

    // Store linear depth (distance from camera) in alpha for DoF
    float linear_depth = length(world_pos - scene.camera_pos.xyz);
    out_color = vec4(color, linear_depth);
}
