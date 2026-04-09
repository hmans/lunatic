#version 450

// ============================================================================
// SSR Temporal Resolve — Lunatic Engine
// ============================================================================
//
// Blends the current frame's SSR trace result with the previous frame's
// accumulated SSR using motion-aware reprojection. This effectively multiplies
// the sample count by accumulating jittered samples across frames, producing
// smooth reflections from noisy per-frame traces.
//
// Algorithm:
//   1. Read current frame's SSR at this pixel
//   2. Reconstruct world position from depth + inverse VP
//   3. Reproject to previous frame's screen UV using prev_vp
//   4. Sample previous SSR history at reprojected UV
//   5. Reject stale history if the reprojected UV is off-screen or the depth
//      changed significantly (disocclusion)
//   6. Blend: result = mix(history, current, blend_factor)
//      Low blend_factor (0.05-0.15) = smooth but laggy
//      High blend_factor (0.3-0.5) = responsive but noisier
//
// Pipeline position: SSR trace → [this shader] → SSR composite → DoF → bloom
// ============================================================================

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

// Current frame's raw SSR trace result
layout(set = 2, binding = 0) uniform sampler2D current_ssr;

// Previous frame's resolved SSR (accumulated history)
layout(set = 2, binding = 1) uniform sampler2D history_ssr;

// Scene depth (for reprojection)
layout(set = 2, binding = 2) uniform sampler2D scene_tex;

layout(set = 3, binding = 0) uniform ResolveParams {
    mat4 vp;        // current VP
    mat4 inv_vp;    // current inverse VP
    mat4 prev_vp;   // previous frame VP
    vec4 params;    // x = blend_factor, y = width, z = height, w = unused
};

void main() {
    vec4 current = texture(current_ssr, frag_uv);
    float depth = texture(scene_tex, frag_uv).a;

    // Sky: no SSR history needed
    if (depth > 500.0) {
        out_color = current;
        return;
    }

    // Reconstruct world position
    vec2 ndc_xy = vec2(frag_uv.x * 2.0 - 1.0, -(frag_uv.y * 2.0 - 1.0));
    vec4 clip_far = inv_vp * vec4(ndc_xy, 1.0, 1.0);
    vec4 clip_near = inv_vp * vec4(ndc_xy, 0.0, 1.0);
    vec3 world_far = clip_far.xyz / clip_far.w;
    vec3 world_near = clip_near.xyz / clip_near.w;
    vec3 ray_dir = normalize(world_far - world_near);
    // camera_pos is at world_near for a perspective camera
    vec3 world_pos = world_near + ray_dir * depth;

    // Reproject to previous frame's screen space
    vec4 prev_clip = prev_vp * vec4(world_pos, 1.0);
    if (prev_clip.w <= 0.0) {
        out_color = current;
        return;
    }
    vec3 prev_ndc = prev_clip.xyz / prev_clip.w;
    vec2 prev_uv = vec2(prev_ndc.x * 0.5 + 0.5, (-prev_ndc.y) * 0.5 + 0.5);

    // Reject if reprojected UV is off-screen
    if (prev_uv.x < 0.0 || prev_uv.x > 1.0 || prev_uv.y < 0.0 || prev_uv.y > 1.0) {
        out_color = current;
        return;
    }

    // Sample history at reprojected position
    vec4 history = texture(history_ssr, prev_uv);

    // Neighborhood clamping: prevent ghosting by clamping the history to the
    // range of the current frame's nearby values. This rejects stale data
    // (e.g., when an object moves and reveals a previously hidden area).
    // 5-tap cross pattern (center + 4 cardinals) — nearly as effective as
    // full 3x3 for SSR clamping, but saves 4 texture fetches per pixel.
    vec2 t = vec2(1.0 / params.y, 1.0 / params.z);
    vec4 c1 = texture(current_ssr, frag_uv + vec2(    0, -t.y));
    vec4 c3 = texture(current_ssr, frag_uv + vec2(-t.x,     0));
    vec4 c4 = current;
    vec4 c5 = texture(current_ssr, frag_uv + vec2( t.x,     0));
    vec4 c7 = texture(current_ssr, frag_uv + vec2(    0,  t.y));

    vec4 nmin = min(min(c1, c3), min(min(c4, c5), c7));
    vec4 nmax = max(max(c1, c3), max(max(c4, c5), c7));

    // Clamp history to neighborhood bounds (prevents ghosting)
    history = clamp(history, nmin, nmax);

    // Blend current with clamped history
    float blend = params.x;
    out_color = mix(history, current, blend);
}
