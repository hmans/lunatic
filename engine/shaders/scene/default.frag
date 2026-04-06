#version 450

layout(location = 0) in vec3 world_pos;
layout(location = 1) in vec3 world_normal;
layout(location = 2) in vec2 frag_uv;
layout(location = 3) in vec3 world_tangent;
layout(location = 4) in vec3 world_bitangent;

layout(set = 3, binding = 0) uniform SceneUniforms {
    vec4 light_dir;
    vec4 camera_pos;
    vec4 fog_color;        // .xyz = color, .w = fog_enabled
    vec4 fog_params;       // .x = fog_start, .y = fog_end
    vec4 ambient;
    vec4 light_color;      // .xyz = directional light color
    vec4 cluster_grid;     // .x = nx, .y = ny, .z = nz, .w = num_lights
    vec4 cluster_depth;    // .x = near, .y = far, .z = log(far/near)
    vec4 cluster_screen;   // .x = screen_w, .y = screen_h, .z = tiles_per_pixel_x, .w = tiles_per_pixel_y
} scene;

layout(set = 3, binding = 1) uniform MaterialUniforms {
    vec4 albedo;
    vec4 material_params;  // .x = metallic, .y = roughness
    vec4 texture_flags;    // .x = has_base_color, .y = has_mr, .z = has_normal, .w = has_emissive
    vec4 emissive;         // .xyz = emissive factor, .w = has_occlusion
} mat;

layout(set = 3, binding = 2) uniform ShadowUniforms {
    mat4 light_vp[4];
    vec4 cascade_splits;
    vec4 shadow_params;    // .x = atlas_size, .y = cascade_size, .z = bias, .w = enabled
} shadow;

layout(set = 2, binding = 0) uniform sampler2D base_color_tex;
layout(set = 2, binding = 1) uniform sampler2D metallic_roughness_tex;
layout(set = 2, binding = 2) uniform sampler2D normal_tex;
layout(set = 2, binding = 3) uniform sampler2D emissive_tex;
layout(set = 2, binding = 4) uniform sampler2D occlusion_tex;
layout(set = 2, binding = 5) uniform sampler2D shadow_atlas;

// ---- Clustered Lighting (storage buffer bindings shifted for shadow uniform) ----

struct GPULight {
    vec4 pos_radius;     // xyz = world position, w = radius
    vec4 color_type;     // xyz = color*intensity, w = type (0=point, 1=spot)
    vec4 dir_spot;       // xyz = direction (spot only)
    vec4 cone_params;    // x = cos(inner_cone), y = cos(outer_cone)
};

layout(std430, set = 1, binding = 3) readonly buffer LightBuffer {
    GPULight lights[];
};

layout(std430, set = 1, binding = 4) readonly buffer ClusterInfoBuffer {
    uvec2 cluster_infos[];  // x = offset, y = count
};

layout(std430, set = 1, binding = 5) readonly buffer LightIndexBuffer {
    uint light_indices[];
};

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

// ---- Shadow Sampling ----

float sampleShadowCascade(vec3 pos, int cascade) {
    vec4 sc = shadow.light_vp[cascade] * vec4(pos, 1.0);
    sc.xyz /= sc.w;
    sc.x = sc.x * 0.5 + 0.5;
    sc.y = (-sc.y) * 0.5 + 0.5;  // flip Y: Metal render targets have inverted Y vs clip space

    if (sc.x < 0.0 || sc.x > 1.0 ||
        sc.y < 0.0 || sc.y > 1.0 ||
        sc.z < 0.0 || sc.z > 1.0) return 1.0;

    // Map to atlas tile UV (2x2 grid)
    vec2 tile_offset;
    if (cascade == 0)      tile_offset = vec2(0.0, 0.0);
    else if (cascade == 1) tile_offset = vec2(0.5, 0.0);
    else if (cascade == 2) tile_offset = vec2(0.0, 0.5);
    else                   tile_offset = vec2(0.5, 0.5);

    vec2 atlas_uv = sc.xy * 0.5 + tile_offset;
    float bias = shadow.shadow_params.z;
    float depth = sc.z - bias;

    // 4-tap PCF for softer shadow edges
    float texel = 1.0 / shadow.shadow_params.x; // 1 / atlas_size
    float result = 0.0;
    result += depth <= texture(shadow_atlas, atlas_uv + vec2(-texel, -texel)).r ? 1.0 : 0.0;
    result += depth <= texture(shadow_atlas, atlas_uv + vec2( texel, -texel)).r ? 1.0 : 0.0;
    result += depth <= texture(shadow_atlas, atlas_uv + vec2(-texel,  texel)).r ? 1.0 : 0.0;
    result += depth <= texture(shadow_atlas, atlas_uv + vec2( texel,  texel)).r ? 1.0 : 0.0;
    return result * 0.25;
}

float sampleShadow(vec3 frag_world_pos, vec3 N, vec3 L) {
    if (shadow.shadow_params.w < 0.5) return 1.0;

    float NdotL = dot(N, L);
    // Surfaces facing away from the light can't be in shadow
    if (NdotL <= 0.0) return 1.0;

    // Normal-offset bias: push the sample point along the normal to reduce
    // self-shadowing on surfaces nearly parallel to the light
    float normal_bias = 0.05 * (1.0 - NdotL);
    vec3 biased_pos = frag_world_pos + N * normal_bias;

    // Select cascade by view-space distance
    float view_depth = length(frag_world_pos - scene.camera_pos.xyz);

    int cascade = 3;
    for (int i = 0; i < 4; i++) {
        if (view_depth < shadow.cascade_splits[i]) {
            cascade = i;
            break;
        }
    }

    return sampleShadowCascade(biased_pos, cascade);
}

// ---- Point/Spot Light Evaluation ----

vec3 evaluateLight(GPULight light, vec3 N, vec3 V, float NdotV, vec3 frag_pos,
                   vec3 base_color, float metallic, float roughness, vec3 F0) {
    vec3 L_vec = light.pos_radius.xyz - frag_pos;
    float dist = length(L_vec);
    float radius = light.pos_radius.w;

    if (dist > radius) return vec3(0.0);

    vec3 L = L_vec / dist;
    float NdotL = max(dot(N, L), 0.0);
    if (NdotL <= 0.0) return vec3(0.0);

    // Physically-based inverse-square attenuation with smooth window to zero at radius
    float d2 = dist * dist;
    float r2 = radius * radius;
    float ratio4 = (d2 * d2) / (r2 * r2);
    float window = clamp(1.0 - ratio4, 0.0, 1.0);
    window *= window;
    float att = window / (d2 + 1.0);

    // Spot light cone falloff
    if (light.color_type.w > 0.5) {
        vec3 spot_dir = normalize(light.dir_spot.xyz);
        float cos_angle = dot(-L, spot_dir);
        float cos_inner = light.cone_params.x;
        float cos_outer = light.cone_params.y;
        float spot_factor = clamp((cos_angle - cos_outer) / (cos_inner - cos_outer + 0.0001), 0.0, 1.0);
        att *= spot_factor;
    }

    if (att <= 0.0) return vec3(0.0);

    // PBR BRDF
    vec3 H = normalize(V + L);
    float NdotH = max(dot(N, H), 0.0);
    float HdotV = max(dot(H, V), 0.0);

    float D = distributionGGX(NdotH, roughness);
    float G = geometrySmith(NdotV, NdotL, roughness);
    vec3  F = fresnelSchlick(HdotV, F0);

    vec3 specular = (D * G * F) / (4.0 * NdotV * NdotL + 0.0001);
    vec3 kD = (1.0 - F) * (1.0 - metallic);
    vec3 diffuse = kD * base_color / PI;

    vec3 radiance = light.color_type.xyz * att;
    return (diffuse + specular) * radiance * NdotL;
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
    float roughness = max(mat.material_params.y, 0.04);

    // Base color
    vec3 base_color = mat.albedo.xyz;
    if (mat.texture_flags.x > 0.5) {
        base_color *= texture(base_color_tex, frag_uv).xyz;
    }

    // Metallic/roughness texture
    if (mat.texture_flags.y > 0.5) {
        vec3 mr = texture(metallic_roughness_tex, frag_uv).xyz;
        roughness *= mr.g;
        metallic *= mr.b;
        roughness = max(roughness, 0.04);
    }

    // Specular anti-aliasing
    float sigma2 = dot(fwidth(N), vec3(0.333));
    roughness = sqrt(roughness * roughness + sigma2 * sigma2);

    // Cook-Torrance BRDF
    float NdotL = max(dot(N, L), 0.0);
    float NdotV = max(dot(N, V), 0.001);
    float NdotH = max(dot(N, H), 0.0);
    float HdotV = max(dot(H, V), 0.0);

    vec3 F0 = mix(vec3(0.04), base_color, metallic);

    float D = distributionGGX(NdotH, roughness);
    float G = geometrySmith(NdotV, NdotL, roughness);
    vec3  F = fresnelSchlick(HdotV, F0);

    vec3 specular = (D * G * F) / (4.0 * NdotV * NdotL + 0.0001);
    vec3 kD = (1.0 - F) * (1.0 - metallic);
    vec3 diffuse = kD * base_color / PI;

    // Direct lighting (directional) with shadow
    float shadow_factor = sampleShadow(world_pos, N, L);

    vec3 color = (diffuse + specular) * NdotL * scene.light_color.xyz * shadow_factor;


    // Ambient (unaffected by shadow)
    vec3 ambient_color = scene.ambient.xyz * base_color;

    // Occlusion (modulates ambient only)
    if (mat.emissive.w > 0.5) {
        float ao = texture(occlusion_tex, frag_uv).r;
        ambient_color *= ao;
    }

    color += ambient_color;

    // Clustered point/spot lights (unaffected by directional shadow)
    if (scene.cluster_grid.w > 0.0) {
        float linear_dist = length(world_pos - scene.camera_pos.xyz);
        float tile_w = scene.cluster_screen.x / scene.cluster_grid.x;
        float tile_h = scene.cluster_screen.y / scene.cluster_grid.y;
        uint cx = min(uint(gl_FragCoord.x / tile_w), uint(scene.cluster_grid.x) - 1u);
        uint cy = min(uint(gl_FragCoord.y / tile_h), uint(scene.cluster_grid.y) - 1u);

        float near = scene.cluster_depth.x;
        float log_ratio = scene.cluster_depth.z;
        uint cz = uint(log(max(linear_dist, near) / near) / log_ratio * scene.cluster_grid.z);
        cz = min(cz, uint(scene.cluster_grid.z) - 1u);

        uint cluster_idx = cx + cy * uint(scene.cluster_grid.x) + cz * uint(scene.cluster_grid.x) * uint(scene.cluster_grid.y);
        uvec2 info = cluster_infos[cluster_idx];
        uint offset = info.x;
        uint count = info.y;

        for (uint i = 0u; i < count; i++) {
            uint light_idx = light_indices[offset + i];
            color += evaluateLight(lights[light_idx], N, V, NdotV, world_pos,
                                   base_color, metallic, roughness, F0);
        }
    }

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

    // Clamp to sane HDR range
    color = min(color, vec3(64.0));

    // Store linear depth in alpha for DoF
    float linear_depth = length(world_pos - scene.camera_pos.xyz);
    out_color = vec4(color, linear_depth);
}
