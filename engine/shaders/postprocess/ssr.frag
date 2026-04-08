#version 450

// ============================================================================
// Screen-Space Reflections (SSR) — Lunatic Engine
// ============================================================================
//
// Screen-space ray march using actual surface normals and roughness from the
// scene's normal+roughness render target (MRT output from default.frag).
//
// Algorithm (McGuire/Mara style):
//   1. Read world-space normal + roughness from the G-buffer
//   2. Reconstruct world position from linear depth + inverse VP
//   3. Compute reflection direction R = reflect(-V, N)
//   4. Project ray start/end to screen space, march via DDA with
//      perspective-correct depth interpolation (1/z linear in screen space)
//   5. On hit: binary refine for sub-pixel accuracy
//   6. Attenuate by Fresnel, roughness, screen-edge fade, distance fade
//
// Pipeline position: Scene HDR → [this shader] → SSR composite → DoF → bloom
// ============================================================================

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D scene_tex;       // HDR scene: rgb=color, a=linear depth
layout(set = 2, binding = 1) uniform sampler2D normal_rough_tex; // xyz=packed normal, w=roughness

layout(set = 3, binding = 0) uniform SSRParams {
    mat4 vp;
    mat4 inv_vp;
    vec4 camera_pos;
    vec4 params;   // x = intensity, y = max_distance, z = stride (pixels), w = thickness
    vec4 screen;   // x = width, y = height, z = max_mip, w = frame_index (for time-varying jitter)
};

// ---------------------------------------------------------------------------
// World position from UV + linear depth
// ---------------------------------------------------------------------------

vec3 worldFromUV(vec2 uv, float linear_depth) {
    vec2 ndc_xy = vec2(uv.x * 2.0 - 1.0, -(uv.y * 2.0 - 1.0));
    vec4 clip_far = inv_vp * vec4(ndc_xy, 1.0, 1.0);
    vec4 clip_near = inv_vp * vec4(ndc_xy, 0.0, 1.0);
    vec3 world_far = clip_far.xyz / clip_far.w;
    vec3 world_near = clip_near.xyz / clip_near.w;
    vec3 ray_dir = normalize(world_far - world_near);
    return camera_pos.xyz + ray_dir * linear_depth;
}

// ---------------------------------------------------------------------------
// Project world → screen UV + linear depth
// ---------------------------------------------------------------------------

vec3 projectToScreen(vec3 wp) {
    vec4 clip = vp * vec4(wp, 1.0);
    if (clip.w <= 0.0) return vec3(-1.0);
    vec3 ndc = clip.xyz / clip.w;
    return vec3(ndc.x * 0.5 + 0.5, (-ndc.y) * 0.5 + 0.5,
                length(wp - camera_pos.xyz));
}

// ---------------------------------------------------------------------------
// Interleaved gradient noise (Jorge Jimenez, 2014)
// Converts coherent stepping artifacts into imperceptible high-frequency noise.
// ---------------------------------------------------------------------------

float interleavedGradientNoise(vec2 pos, float frame) {
    // Time-varying jitter: offset the noise pattern each frame so temporal
    // accumulation gathers samples at different positions across frames.
    return fract(52.9829189 * fract(0.06711056 * pos.x + 0.00583715 * pos.y + frame * 0.1193));
}

// ---------------------------------------------------------------------------
// Screen-space ray march with jitter + binary refinement
// ---------------------------------------------------------------------------

bool traceRay(vec3 origin, vec3 dir, vec2 frag_coord, out vec2 hit_uv, out float hit_conf) {
    float max_dist = params.y;
    float pixel_stride = params.z;
    float thickness = params.w;

    vec3 ray_end_world = origin + dir * max_dist;
    vec3 p0 = projectToScreen(origin);
    vec3 p1 = projectToScreen(ray_end_world);

    if (p0.z < 0.0) return false;

    // Handle ray end behind camera: shorten
    if (p1.x < -0.5) {
        for (int k = 4; k >= 1; k--) {
            p1 = projectToScreen(origin + dir * max_dist * float(k) * 0.2);
            if (p1.x >= -0.5) break;
        }
        if (p1.x < -0.5) return false;
    }

    // Screen-space ray
    vec2 ray_uv = p1.xy - p0.xy;
    float ray_len_px = length(ray_uv * vec2(screen.x, screen.y));
    if (ray_len_px < 1.0) return false;

    int num_steps = int(min(ray_len_px / pixel_stride, 128.0));
    if (num_steps < 1) return false;

    vec2 step_uv = ray_uv / float(num_steps);

    // Perspective-correct depth: interpolate 1/z linearly
    float inv_z0 = 1.0 / max(p0.z, 0.001);
    float inv_z1 = 1.0 / max(p1.z, 0.001);
    float step_inv_z = (inv_z1 - inv_z0) / float(num_steps);

    // Jitter the ray start by a per-pixel random offset (0..1 step).
    // This converts coherent banding/ring artifacts into high-frequency noise
    // that's much less visible and blends away with bloom/DoF.
    float jitter = interleavedGradientNoise(frag_coord, screen.w);
    float start_offset = 2.0 + jitter; // 2 steps for self-intersection avoidance + random offset

    vec2 cur_uv = p0.xy + step_uv * start_offset;
    float cur_inv_z = inv_z0 + step_inv_z * start_offset;

    vec2 prev_uv = cur_uv;
    float prev_inv_z = cur_inv_z;

    for (int i = 2; i < num_steps; i++) {
        prev_uv = cur_uv;
        prev_inv_z = cur_inv_z;
        cur_uv += step_uv;
        cur_inv_z += step_inv_z;

        if (cur_uv.x < 0.0 || cur_uv.x > 1.0 || cur_uv.y < 0.0 || cur_uv.y > 1.0)
            return false;

        float cur_depth = 1.0 / cur_inv_z;
        float scene_depth = texture(scene_tex, cur_uv).a;

        if (scene_depth > 500.0) continue; // skip sky

        float depth_diff = cur_depth - scene_depth;

        if (depth_diff > 0.0 && depth_diff < thickness) {
            // Coarse hit found — binary refine between prev and cur for precision
            vec2 lo_uv = prev_uv;
            float lo_inv_z = prev_inv_z;
            vec2 hi_uv = cur_uv;
            float hi_inv_z = cur_inv_z;

            for (int r = 0; r < 6; r++) {
                vec2 mid_uv = (lo_uv + hi_uv) * 0.5;
                float mid_inv_z = (lo_inv_z + hi_inv_z) * 0.5;
                float mid_depth = 1.0 / mid_inv_z;
                float mid_scene = texture(scene_tex, mid_uv).a;
                float mid_diff = mid_depth - mid_scene;

                if (mid_diff > 0.0 && mid_diff < thickness) {
                    hi_uv = mid_uv;
                    hi_inv_z = mid_inv_z;
                } else {
                    lo_uv = mid_uv;
                    lo_inv_z = mid_inv_z;
                }
            }

            hit_uv = (lo_uv + hi_uv) * 0.5;

            // Screen-edge fade
            vec2 ef = smoothstep(vec2(0.0), vec2(0.1), hit_uv) *
                     (1.0 - smoothstep(vec2(0.9), vec2(1.0), hit_uv));
            float t_frac = float(i) / float(num_steps);
            hit_conf = ef.x * ef.y * (1.0 - t_frac * t_frac);
            return true;
        }
    }
    return false;
}

void main() {
    float intensity = params.x;
    if (intensity <= 0.0) { out_color = vec4(0.0); return; }

    float depth = texture(scene_tex, frag_uv).a;
    if (depth > 500.0) { out_color = vec4(0.0); return; }

    // Read actual normal + roughness from G-buffer
    vec4 nr = texture(normal_rough_tex, frag_uv);
    vec3 N = normalize(nr.xyz * 2.0 - 1.0);  // Unpack from [0,1] to [-1,1]
    float roughness = nr.w;

    // Attenuate SSR on very rough surfaces. Rough surfaces scatter reflections
    // over a wide cone, but moderate roughness still produces visible reflections
    // (especially for colored light pools on floors). Only fully suppress at
    // very high roughness (>0.95).
    float roughness_fade = 1.0 - smoothstep(0.6, 0.95, roughness);
    if (roughness_fade < 0.01) { out_color = vec4(0.0); return; }

    vec3 world_pos = worldFromUV(frag_uv, depth);
    vec3 V = normalize(camera_pos.xyz - world_pos);
    float NdotV = max(dot(N, V), 0.0);

    if (NdotV < 0.01) { out_color = vec4(0.0); return; }

    vec3 R = reflect(-V, N);

    // Artistic Fresnel: physically-based Schlick would give near-zero reflections
    // on dielectric surfaces viewed head-on (F0=0.04), which makes SSR invisible
    // from typical camera angles. Use a generous curve that's always visible.
    // The intensity slider provides the user control over overall strength.
    float fresnel = mix(0.3, 1.0, pow(1.0 - NdotV, 3.0));

    vec2 hit_uv;
    float hit_conf;
    if (traceRay(world_pos, R, gl_FragCoord.xy, hit_uv, hit_conf)) {
        vec3 refl = texture(scene_tex, hit_uv).rgb;
        float alpha = hit_conf * fresnel * intensity * roughness_fade;
        out_color = vec4(refl, alpha);
    } else {
        out_color = vec4(0.0);
    }
}
