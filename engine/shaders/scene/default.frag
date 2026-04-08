#version 450

// ============================================================================
// Scene Fragment Shader — Lunatic Engine
// ============================================================================
//
// Physically-based rendering (PBR) with Cook-Torrance BRDF, cascaded shadow
// maps, clustered forward lighting, normal mapping, and fog.
//
// Lighting model:
//   - One directional light (sun) with 4-cascade shadow mapping
//   - Up to 256 point/spot lights via clustered forward shading
//   - Flat ambient term modulated by an optional occlusion map
//   - Emissive surfaces (additive, unaffected by lighting)
//
// Output:
//   .rgb = HDR linear color (clamped to 64.0 to prevent specular fireflies)
//   .a   = linear depth (world-space distance from camera) for the DoF pass
//
// The output goes to an R16G16B16A16_FLOAT render target. Post-processing
// (DoF, bloom, tonemapping) happens in subsequent passes.
// ============================================================================

layout(location = 0) in vec3 world_pos;
layout(location = 1) in vec3 world_normal;
layout(location = 2) in vec2 frag_uv;
layout(location = 3) in vec3 world_tangent;
layout(location = 4) in vec3 world_bitangent;
layout(location = 5) flat in float receives_shadow;

// ---- Uniform Blocks ----

layout(set = 3, binding = 0) uniform SceneUniforms {
    vec4 light_dir;        // .xyz = normalized direction TO the light (not from)
    vec4 camera_pos;       // .xyz = camera world position
    vec4 fog_color;        // .xyz = fog color (sRGB, inverse-ACES-transformed on CPU), .w = fog_enabled
    vec4 fog_params;       // .x = fog_start distance, .y = fog_end distance
    vec4 ambient;          // .xyz = ambient light color
    vec4 light_color;      // .xyz = directional light color * intensity
    vec4 cluster_grid;     // .x = tiles_x, .y = tiles_y, .z = slices_z, .w = total_light_count
    vec4 cluster_depth;    // .x = near plane, .y = far plane, .z = log(far/near)
    vec4 cluster_screen;   // .x = screen_w, .y = screen_h (z,w unused by shader)
} scene;

layout(set = 3, binding = 1) uniform MaterialUniforms {
    vec4 albedo;           // .xyz = base color (linear), .w = alpha (unused currently)
    vec4 material_params;  // .x = metallic [0..1], .y = roughness [0..1]
    vec4 texture_flags;    // .x = has_base_color, .y = has_mr, .z = has_normal, .w = has_emissive
    vec4 emissive;         // .xyz = emissive factor (linear), .w = has_occlusion (1.0 or 0.0)
} mat;

layout(set = 3, binding = 2) uniform ShadowUniforms {
    mat4 light_vp[4];     // Light view-projection matrices, one per cascade
    vec4 cascade_splits;  // View-space distances where each cascade ends [c0, c1, c2, c3]
    vec4 shadow_params;   // .x = atlas_size (px), .y = cascade_size (px), .z = depth bias, .w = enabled
} shadow;

// ---- Textures ----

layout(set = 2, binding = 0) uniform sampler2D base_color_tex;
layout(set = 2, binding = 1) uniform sampler2D metallic_roughness_tex;  // glTF: R=unused, G=roughness, B=metallic
layout(set = 2, binding = 2) uniform sampler2D normal_tex;              // Tangent-space normal map
layout(set = 2, binding = 3) uniform sampler2D emissive_tex;
layout(set = 2, binding = 4) uniform sampler2D occlusion_tex;           // R channel = AO factor
layout(set = 2, binding = 5) uniform sampler2D shadow_atlas;            // 2x2 cascade atlas (depth values)

// ---- Clustered Lighting Buffers ----
//
// The engine builds these each frame on the CPU:
//   1. LightBuffer:      All active point/spot lights (position, color, radius, etc.)
//   2. ClusterInfoBuffer: For each 3D cluster cell, the offset+count into the index buffer
//   3. LightIndexBuffer:  Flat array of light indices, grouped by cluster
//
// The fragment shader determines which cluster this pixel falls into (using
// screen XY + depth Z), then loops over only the lights assigned to that cluster.

struct GPULight {
    vec4 pos_radius;   // .xyz = world position, .w = influence radius
    vec4 color_type;   // .xyz = color * intensity (pre-multiplied), .w = type (0=point, 1=spot)
    vec4 dir_spot;     // .xyz = spot direction (normalized), unused for point lights
    vec4 cone_params;  // .x = cos(inner_cone_angle), .y = cos(outer_cone_angle)
};

layout(std430, set = 1, binding = 3) readonly buffer LightBuffer {
    GPULight lights[];
};

layout(std430, set = 1, binding = 4) readonly buffer ClusterInfoBuffer {
    uvec2 cluster_infos[];  // .x = start offset into light_indices, .y = light count
};

layout(std430, set = 1, binding = 5) readonly buffer LightIndexBuffer {
    uint light_indices[];   // Indices into lights[], grouped by cluster
};

layout(location = 0) out vec4 out_color;
layout(location = 1) out vec4 out_normal_roughness;  // xyz = world-space normal, w = roughness (for SSR)

const float PI = 3.14159265359;

// ============================================================================
// PBR BRDF Functions
// ============================================================================
//
// Implements the Cook-Torrance microfacet specular BRDF:
//   f_spec = D(h) * G(l,v) * F(v,h) / (4 * NdotL * NdotV)
//
// Combined with a Lambertian diffuse term scaled by (1-F)*(1-metallic).
//
// References:
//   - Brian Karis, "Real Shading in Unreal Engine 4", SIGGRAPH 2013
//   - Naty Hoffman, "Background: Physics and Math of Shading", SIGGRAPH 2015

// GGX/Trowbridge-Reitz normal distribution function.
// Controls the shape and size of the specular highlight.
// Higher roughness = wider, dimmer highlight. Lower = tighter, brighter.
float distributionGGX(float NdotH, float roughness) {
    float a = roughness * roughness;       // Remap to perceptual roughness squared
    float a2 = a * a;                      // alpha^2 for the GGX formula
    float denom = NdotH * NdotH * (a2 - 1.0) + 1.0;
    return a2 / (PI * denom * denom);
}

// Smith's geometry function using the Schlick-GGX approximation.
// Models self-shadowing of microfacets — rough surfaces block more light
// at grazing angles. Uses the direct lighting remapping: k = (roughness+1)^2 / 8.
float geometrySmith(float NdotV, float NdotL, float roughness) {
    float r = roughness + 1.0;
    float k = (r * r) / 8.0;              // Schlick remapping for direct lighting
    float ggx1 = NdotV / (NdotV * (1.0 - k) + k);  // Geometry obstruction (view)
    float ggx2 = NdotL / (NdotL * (1.0 - k) + k);  // Geometry shadowing (light)
    return ggx1 * ggx2;
}

// Fresnel-Schlick approximation.
// At grazing angles, all surfaces become reflective (Fresnel effect).
// F0 = reflectance at normal incidence (0.04 for dielectrics, albedo for metals).
vec3 fresnelSchlick(float cosTheta, vec3 F0) {
    return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

// ============================================================================
// Shadow Sampling
// ============================================================================
//
// Uses a 4096x4096 shadow atlas arranged as a 2x2 grid of 2048x2048 cascades:
//   [cascade 0 | cascade 1]
//   [cascade 2 | cascade 3]
//
// Each cascade covers a progressively larger area around the camera.
// Cascade selection is based on view-space distance from the camera.

// Sample a single cascade from the shadow atlas.
// Returns 1.0 = fully lit, 0.0 = fully shadowed.
float sampleShadowCascade(vec3 pos, int cascade) {
    // Project the world position into this cascade's light clip space
    vec4 sc = shadow.light_vp[cascade] * vec4(pos, 1.0);
    sc.xyz /= sc.w;  // Perspective divide (orthographic, so w=1, but kept for correctness)

    // Clip-to-UV mapping. Note the Y flip: on Metal, render target Y is inverted
    // relative to clip space when rendering to non-swapchain textures.
    // See CLAUDE.md "Metal Y-flip for shadow sampling" for details.
    sc.x = sc.x * 0.5 + 0.5;
    sc.y = (-sc.y) * 0.5 + 0.5;

    // If the fragment falls outside this cascade's frustum, treat as fully lit
    // (it will be handled by a larger cascade or is beyond shadow range)
    if (sc.x < 0.0 || sc.x > 1.0 ||
        sc.y < 0.0 || sc.y > 1.0 ||
        sc.z < 0.0 || sc.z > 1.0) return 1.0;

    // Map from cascade-local UV [0,1] to atlas UV by scaling to quarter and offsetting
    vec2 tile_offset;
    if (cascade == 0)      tile_offset = vec2(0.0, 0.0);  // top-left
    else if (cascade == 1) tile_offset = vec2(0.5, 0.0);  // top-right
    else if (cascade == 2) tile_offset = vec2(0.0, 0.5);  // bottom-left
    else                   tile_offset = vec2(0.5, 0.5);  // bottom-right

    vec2 atlas_uv = sc.xy * 0.5 + tile_offset;
    float bias = shadow.shadow_params.z;
    float depth = sc.z - bias;  // Subtract bias to reduce shadow acne

    // 4-tap PCF (percentage-closer filtering) for softer shadow edges.
    // Samples a 2x2 pattern offset by one texel in each direction.
    // More taps = smoother edges but higher cost. 4 is the minimum for
    // acceptable quality. Consider upgrading to 8-16 tap Poisson disk.
    float texel = 1.0 / shadow.shadow_params.x;  // 1 texel in atlas UV space
    float result = 0.0;
    result += depth <= texture(shadow_atlas, atlas_uv + vec2(-texel, -texel)).r ? 1.0 : 0.0;
    result += depth <= texture(shadow_atlas, atlas_uv + vec2( texel, -texel)).r ? 1.0 : 0.0;
    result += depth <= texture(shadow_atlas, atlas_uv + vec2(-texel,  texel)).r ? 1.0 : 0.0;
    result += depth <= texture(shadow_atlas, atlas_uv + vec2( texel,  texel)).r ? 1.0 : 0.0;
    return result * 0.25;
}

// Determine which cascade to use and sample the shadow map.
// Applies normal-offset bias to reduce self-shadowing artifacts on surfaces
// nearly parallel to the light direction.
float sampleShadow(vec3 frag_world_pos, vec3 N, vec3 L) {
    if (shadow.shadow_params.w < 0.5) return 1.0;  // Shadows disabled

    float NdotL = dot(N, L);

    // Surfaces facing away from the light: let the BRDF's own NdotL
    // handle the falloff — returning 0.0 here creates terminator artifacts
    // because the normal-offset bias interacts poorly at grazing angles.
    if (NdotL <= 0.0) return 1.0;

    // Normal-offset bias: push the sample point along the surface normal.
    // The offset is largest when the surface is nearly edge-on to the light
    // (NdotL close to 0), where shadow acne is worst.
    float normal_bias = 0.05 * (1.0 - NdotL);
    vec3 biased_pos = frag_world_pos + N * normal_bias;

    // Select cascade: find the first cascade whose far boundary is beyond
    // this fragment's distance from the camera. Cascade 3 is the fallback
    // (covers the farthest range).
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

// ============================================================================
// Point/Spot Light Evaluation
// ============================================================================
//
// Evaluates a single point or spot light's contribution using the same
// Cook-Torrance BRDF as the directional light. Called once per light per
// fragment from the clustered lighting loop.

vec3 evaluateLight(GPULight light, vec3 N, vec3 V, float NdotV, vec3 frag_pos,
                   vec3 base_color, float metallic, float roughness, vec3 F0) {
    vec3 L_vec = light.pos_radius.xyz - frag_pos;
    float dist = length(L_vec);
    float radius = light.pos_radius.w;

    // Early out: fragment is beyond the light's influence radius
    if (dist > radius) return vec3(0.0);

    vec3 L = L_vec / dist;
    float NdotL = max(dot(N, L), 0.0);
    if (NdotL <= 0.0) return vec3(0.0);  // Surface faces away from this light

    // Physically-based inverse-square attenuation with a smooth window function
    // that reaches exactly zero at the light's radius. This avoids the hard cutoff
    // of a simple clamp while maintaining the 1/d^2 falloff near the light.
    //
    // Formula: window(d) = saturate(1 - (d/r)^4)^2
    //          atten(d)  = window(d) / (d^2 + 1)
    //
    // The +1 in the denominator prevents division by zero at d=0 and also
    // bounds the maximum intensity (a point light at distance 0 has finite brightness).
    // Reference: UE4 light attenuation (Karis 2013)
    float d2 = dist * dist;
    float r2 = radius * radius;
    float ratio4 = (d2 * d2) / (r2 * r2);
    float window = clamp(1.0 - ratio4, 0.0, 1.0);
    window *= window;
    float att = window / (d2 + 1.0);

    // Spot light: apply angular falloff between inner and outer cone angles.
    // cos_angle is the dot product between the light direction and the fragment
    // direction — higher values mean the fragment is more centered in the cone.
    if (light.color_type.w > 0.5) {  // type 1 = spot light
        vec3 spot_dir = normalize(light.dir_spot.xyz);
        float cos_angle = dot(-L, spot_dir);
        float cos_inner = light.cone_params.x;
        float cos_outer = light.cone_params.y;
        // Smooth falloff from full intensity at inner cone to zero at outer cone
        float spot_factor = clamp((cos_angle - cos_outer) / (cos_inner - cos_outer + 0.0001), 0.0, 1.0);
        att *= spot_factor;
    }

    if (att <= 0.0) return vec3(0.0);

    // Same Cook-Torrance BRDF as the directional light
    vec3 H = normalize(V + L);
    float NdotH = max(dot(N, H), 0.0);
    float HdotV = max(dot(H, V), 0.0);

    float D = distributionGGX(NdotH, roughness);
    float G = geometrySmith(NdotV, NdotL, roughness);
    vec3  F = fresnelSchlick(HdotV, F0);

    vec3 specular = (D * G * F) / (4.0 * NdotV * NdotL + 0.0001);
    vec3 kD = (1.0 - F) * (1.0 - metallic);  // Metals have no diffuse
    vec3 diffuse = kD * base_color / PI;

    vec3 radiance = light.color_type.xyz * att;  // color * intensity * attenuation
    return (diffuse + specular) * radiance * NdotL;
}

// ============================================================================
// Main
// ============================================================================

void main() {
    vec3 N = normalize(world_normal);

    // Normal mapping: perturb the interpolated normal using the tangent-space
    // normal map. The TBN matrix transforms from tangent space to world space.
    if (mat.texture_flags.z > 0.5) {
        vec3 T = normalize(world_tangent);
        vec3 B = normalize(world_bitangent);
        mat3 TBN = mat3(T, B, N);
        vec3 map_normal = texture(normal_tex, frag_uv).xyz * 2.0 - 1.0;  // Unpack [0,1] -> [-1,1]
        N = normalize(TBN * map_normal);
    }

    // Precompute shared vectors and distance (used by clustering, fog, and depth output)
    float frag_dist = length(world_pos - scene.camera_pos.xyz);
    vec3 V = normalize(scene.camera_pos.xyz - world_pos);  // View direction (toward camera)
    vec3 L = normalize(scene.light_dir.xyz);                // Light direction (toward sun)
    vec3 H = normalize(V + L);                              // Half vector (for specular)

    // ---- Material Setup ----

    float metallic = mat.material_params.x;
    float roughness = max(mat.material_params.y, 0.04);  // Clamp to avoid division issues at roughness=0

    vec3 base_color = mat.albedo.xyz;
    if (mat.texture_flags.x > 0.5) {
        base_color *= texture(base_color_tex, frag_uv).xyz;
    }

    // glTF metallic-roughness texture: green = roughness, blue = metallic
    if (mat.texture_flags.y > 0.5) {
        vec3 mr = texture(metallic_roughness_tex, frag_uv).xyz;
        roughness *= mr.g;
        metallic *= mr.b;
        roughness = max(roughness, 0.04);
    }

    // Specular anti-aliasing: widen the roughness based on how rapidly the
    // normal changes across the pixel. This prevents bright specular fireflies
    // on small or distant geometry where the normal varies sub-pixel.
    // Reference: Kaplanyan & Hill, "Stable Geometric Specular AA", 2016
    float sigma2 = dot(fwidth(N), vec3(0.333));  // Average screen-space normal derivative
    roughness = sqrt(roughness * roughness + sigma2 * sigma2);

    // ---- Cook-Torrance BRDF (Directional Light) ----

    float NdotL = max(dot(N, L), 0.0);
    float NdotV = max(dot(N, V), 0.001);  // Clamp above zero to avoid specular artifacts at silhouettes
    float NdotH = max(dot(N, H), 0.0);
    float HdotV = max(dot(H, V), 0.0);

    // F0 = reflectance at normal incidence. Dielectrics ~0.04, metals use their base color.
    vec3 F0 = mix(vec3(0.04), base_color, metallic);

    float D = distributionGGX(NdotH, roughness);
    float G = geometrySmith(NdotV, NdotL, roughness);
    vec3  F = fresnelSchlick(HdotV, F0);

    // Specular: microfacet Cook-Torrance. The 0.0001 prevents div-by-zero.
    vec3 specular = (D * G * F) / (4.0 * NdotV * NdotL + 0.0001);
    // Diffuse: energy-conserving Lambertian. (1-F) = energy not reflected as specular.
    // (1-metallic) = metals have no diffuse component.
    vec3 kD = (1.0 - F) * (1.0 - metallic);
    vec3 diffuse = kD * base_color / PI;

    // ---- Direct Lighting (Sun) ----

    float shadow_factor = receives_shadow > 0.5 ? sampleShadow(world_pos, N, L) : 1.0;
    vec3 color = (diffuse + specular) * NdotL * scene.light_color.xyz * shadow_factor;

    // ---- Ambient ----
    // Simple constant ambient, modulated by optional occlusion map.
    // Ambient is intentionally NOT affected by shadows — even shadowed surfaces
    // receive indirect light.

    vec3 ambient_color = scene.ambient.xyz * base_color;

    if (mat.emissive.w > 0.5) {  // has_occlusion flag (packed in emissive.w)
        float ao = texture(occlusion_tex, frag_uv).r;
        ambient_color *= ao;
    }

    color += ambient_color;

    // ---- Clustered Point/Spot Lights ----
    //
    // The view frustum is divided into a 3D grid of clusters (tiles in XY,
    // slices in Z). Each cluster has a precomputed list of lights that
    // overlap it. We look up which cluster this fragment belongs to and
    // only evaluate those lights — O(lights_per_cluster) instead of O(total_lights).
    //
    // Z slicing uses logarithmic distribution (more slices near the camera
    // where light density is typically higher).

    if (scene.cluster_grid.w > 0.0) {  // .w = total light count; skip if no lights
        // XY cluster index from screen-space position
        float tile_w = scene.cluster_screen.x / scene.cluster_grid.x;
        float tile_h = scene.cluster_screen.y / scene.cluster_grid.y;
        uint cx = min(uint(gl_FragCoord.x / tile_w), uint(scene.cluster_grid.x) - 1u);
        uint cy = min(uint(gl_FragCoord.y / tile_h), uint(scene.cluster_grid.y) - 1u);

        // Z cluster index from logarithmic depth
        float near = scene.cluster_depth.x;
        float log_ratio = scene.cluster_depth.z;  // = log(far/near)
        uint cz = uint(log(max(frag_dist, near) / near) / log_ratio * scene.cluster_grid.z);
        cz = min(cz, uint(scene.cluster_grid.z) - 1u);

        // Linearize 3D cluster index to 1D buffer offset
        uint cluster_idx = cx + cy * uint(scene.cluster_grid.x) + cz * uint(scene.cluster_grid.x) * uint(scene.cluster_grid.y);
        uvec2 info = cluster_infos[cluster_idx];
        uint offset = info.x;  // Start index in light_indices[]
        uint count = info.y;   // Number of lights in this cluster

        for (uint i = 0u; i < count; i++) {
            uint light_idx = light_indices[offset + i];
            color += evaluateLight(lights[light_idx], N, V, NdotV, world_pos,
                                   base_color, metallic, roughness, F0);
        }
    }

    // ---- Emissive ----
    // Additive, unaffected by lighting or shadows. Drives bloom naturally
    // since emissive values can exceed 1.0 in HDR.
    vec3 emissive_color = mat.emissive.xyz;
    if (mat.texture_flags.w > 0.5) {
        emissive_color *= texture(emissive_tex, frag_uv).xyz;
    }
    color += emissive_color;

    // ---- Fog ----
    // Linear fog based on world-space distance from camera.
    // fog_color is pre-transformed on the CPU (inverse ACES) so it
    // round-trips correctly through the tonemapper in the composite pass.
    if (scene.fog_color.w > 0.5) {
        float fog_start = scene.fog_params.x;
        float fog_end = scene.fog_params.y;
        float fog_factor = clamp((frag_dist - fog_start) / (fog_end - fog_start), 0.0, 1.0);
        color = mix(color, scene.fog_color.xyz, fog_factor);
    }

    // Clamp HDR output to prevent extreme values from causing bloom artifacts
    // or NaN propagation. 64.0 is high enough for realistic highlights but
    // low enough to prevent specular fireflies from dominating the bloom pass.
    color = min(color, vec3(64.0));

    // Store linear depth in alpha for the DoF pass. The DoF CoC shader reads
    // this to compute circle of confusion without a separate depth buffer.
    // Background/sky fragments get alpha = 1000.0 from the clear color.
    out_color = vec4(color, frag_dist);

    // Normal + roughness for screen-space reflections.
    // N is the final world-space normal (after normal mapping + specular AA).
    // Roughness is used to attenuate SSR (rough surfaces get less reflection).
    out_normal_roughness = vec4(N * 0.5 + 0.5, roughness);  // Pack normal to [0,1]
}
