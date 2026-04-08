#version 450

// ============================================================================
// SSR Composite — Lunatic Engine
// ============================================================================
//
// Blends screen-space reflection results back into the HDR scene.
// The SSR texture contains: .rgb = reflected color, .a = confidence/opacity.
// The composite simply adds the reflection weighted by confidence.
//
// Pipeline position: Scene HDR → SSR trace → [this shader] → DoF → bloom
// ============================================================================

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

// Original scene HDR (color + depth in alpha)
layout(set = 2, binding = 0) uniform sampler2D scene_tex;

// SSR result (.rgb = reflection, .a = confidence)
layout(set = 2, binding = 1) uniform sampler2D ssr_tex;

layout(set = 3, binding = 0) uniform SSRCompositeParams {
    vec4 params; // .xy = texel size, .zw = unused
};

void main() {
    vec4 scene = texture(scene_tex, frag_uv);
    vec2 t = params.xy;

    // 9-tap tent filter on the SSR result to smooth out jitter/dither noise.
    // Weights: center=4, edges=2, corners=1, total=16
    vec4 ssr = texture(ssr_tex, frag_uv) * 4.0
             + texture(ssr_tex, frag_uv + vec2(-t.x, 0)) * 2.0
             + texture(ssr_tex, frag_uv + vec2( t.x, 0)) * 2.0
             + texture(ssr_tex, frag_uv + vec2(0, -t.y)) * 2.0
             + texture(ssr_tex, frag_uv + vec2(0,  t.y)) * 2.0
             + texture(ssr_tex, frag_uv + vec2(-t.x, -t.y))
             + texture(ssr_tex, frag_uv + vec2( t.x, -t.y))
             + texture(ssr_tex, frag_uv + vec2(-t.x,  t.y))
             + texture(ssr_tex, frag_uv + vec2( t.x,  t.y));
    ssr *= (1.0 / 16.0);

    // Energy-conserving blend
    vec3 color = mix(scene.rgb, ssr.rgb, ssr.a);

    // Preserve the original linear depth in alpha (needed by DoF)
    out_color = vec4(color, scene.a);
}
