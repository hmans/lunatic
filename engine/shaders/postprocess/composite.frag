#version 450

// ============================================================================
// Final Composite Shader — Lunatic Engine
// ============================================================================
//
// The last rendering pass: combines the HDR scene with bloom, lens flare, and
// lens dirt, then applies tonemapping and camera effects to produce the final
// LDR image for display.
//
// Processing order (each step is skipped if its intensity is zero):
//   1. Chromatic aberration — per-channel UV offset (radial, distance-squared)
//   2. Bloom addition — additive blend of the bloom mip chain
//   3. Lens flare — additive blend of ghost/halo texture
//   4. Lens dirt — bloom/flare-driven dirt smudge overlay
//   5. Exposure — linear brightness multiplier
//   6. Color temperature — warm/cool white balance shift
//   7. ACES tonemapping — HDR -> LDR curve (Narkowicz approximation)
//   8. Gamma correction — linear -> sRGB (simple pow 2.2)
//   9. Vignette — darken screen edges (radial gradient)
//  10. Film grain — animated noise (applied in gamma space, like real film)
//
// All additive effects (bloom, flare, dirt) are applied BEFORE tonemapping
// so they compress naturally with the rest of the scene rather than clipping.
// Vignette and grain are applied AFTER gamma because they're perceptual effects
// that should interact with the displayed brightness, not the linear light values.
// ============================================================================

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D hdr_scene;  // HDR scene (after DoF if active)
layout(set = 2, binding = 1) uniform sampler2D bloom_tex;   // Bloom result (upsample chain output)
layout(set = 2, binding = 2) uniform sampler2D flare_tex;   // Lens flare ghosts + halo
layout(set = 2, binding = 3) uniform sampler2D dirt_tex;    // Lens dirt overlay texture

layout(set = 3, binding = 0) uniform CompositeParams {
    vec4 params;   // .x = bloom_intensity, .y = exposure, .z = flare_intensity, .w = dirt_intensity
    vec4 params2;  // .x = vignette_intensity, .y = vignette_smoothness
    vec4 params3;  // .x = chromatic_aberration, .y = grain_intensity, .z = grain_time (animated seed)
    vec4 params4;  // .x = color_temp (negative = cool/blue, positive = warm/amber)
} composite;

// Fast hash function for film grain noise. Produces a pseudo-random value in [0,1]
// from a 2D coordinate. The grain_time offset makes it animate per-frame.
float hash(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

void main() {
    vec2 uv = frag_uv;

    // ---- Chromatic Aberration ----
    // Simulates the color fringing of real lenses: each wavelength (R, G, B)
    // focuses at a slightly different distance from the optical axis.
    // Red is offset outward, blue inward (or vice versa), green stays centered.
    // The offset magnitude is proportional to distance^2 from screen center,
    // matching the radial distortion profile of real lenses.
    float ca_strength = composite.params3.x;
    vec3 color;
    if (ca_strength > 0.0) {
        vec2 uv_centered = uv - 0.5;
        float dist2 = dot(uv_centered, uv_centered);  // Squared distance from center
        vec2 offset = uv_centered * dist2 * ca_strength;

        // Sample each color channel at a different UV offset
        float r = texture(hdr_scene, uv + offset).r;   // Red: offset outward
        float g = texture(hdr_scene, uv).g;             // Green: no offset (reference)
        float b = texture(hdr_scene, uv - offset).b;    // Blue: offset inward
        color = vec3(r, g, b);

        // Apply same CA to bloom so it matches the scene fringing
        float br = texture(bloom_tex, uv + offset).r;
        float bg = texture(bloom_tex, uv).g;
        float bb = texture(bloom_tex, uv - offset).b;
        color += vec3(br, bg, bb) * composite.params.x;

        // Lens flare with slightly reduced CA (flares are already soft)
        float flare_intensity = composite.params.z;
        if (flare_intensity > 0.0) {
            float fr = texture(flare_tex, uv + offset * 0.5).r;
            float fg = texture(flare_tex, uv).g;
            float fb = texture(flare_tex, uv - offset * 0.5).b;
            color += vec3(fr, fg, fb) * flare_intensity;
        }
    } else {
        // No CA: simple additive blend (cheaper — single texture fetch per source)
        color = texture(hdr_scene, uv).rgb;
        color += texture(bloom_tex, uv).rgb * composite.params.x;
        color += texture(flare_tex, uv).rgb * composite.params.z;
    }

    // ---- Lens Dirt ----
    // Simulates smudges and dust on the camera lens. The dirt texture is a
    // grayscale pattern that modulates the glow from bloom and flare — dirt
    // is only visible where there's already bright light to scatter through it.
    float dirt_intensity = composite.params.w;
    if (dirt_intensity > 0.0) {
        vec3 dirt = texture(dirt_tex, uv).rgb;

        // Use bloom + flare luminance as the "glow driver" — dirt amplifies existing glow
        float bloom_lum = dot(texture(bloom_tex, uv).rgb, vec3(0.2126, 0.7152, 0.0722));
        float flare_lum = dot(texture(flare_tex, uv).rgb, vec3(0.2126, 0.7152, 0.0722));
        float glow = bloom_lum * composite.params.x + flare_lum * 0.3;

        // Soft threshold: dirt only appears where glow is significant,
        // preventing faint noise in dark areas
        float dirt_mask = smoothstep(0.05, 0.25, glow);

        // The 8x multiplier is an artistic scaling factor to bring the
        // dirt into a visually useful range without requiring extreme
        // dirt_intensity values from the user.
        color += dirt * glow * dirt_mask * dirt_intensity * 8.0;
    }

    // ---- Exposure ----
    // Simple linear exposure control. Applied before tonemapping so it
    // affects the curve's input range — higher exposure compresses more
    // of the highlight range, lower exposure preserves more detail in brights.
    color *= composite.params.y;

    // ---- Color Temperature ----
    // Approximate white balance shift. Positive = warm (boost red, cut blue),
    // negative = cool (boost blue, cut red). The 0.1 scale factor keeps the
    // control gentle — a temp value of 1.0 gives a subtle warming.
    float temp = composite.params4.x;
    if (abs(temp) > 0.001) {
        color *= vec3(1.0 + temp * 0.1, 1.0, 1.0 - temp * 0.1);
    }

    // ---- ACES Tonemapping ----
    // Narkowicz approximation of the ACES filmic curve (RRT + ODT).
    // Maps HDR [0, inf) to LDR [0, 1] with a pleasing S-curve:
    // - Toe: lifts shadows slightly (cinematic look)
    // - Shoulder: compresses highlights gradually (no hard clipping)
    // - Known issue: oversaturates warm colors (reds/oranges) at high exposure
    // Reference: Krzysztof Narkowicz, "ACES Filmic Tone Mapping Curve", 2015
    color = clamp((color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14), 0.0, 1.0);

    // ---- Gamma Correction ----
    // Convert from linear light to sRGB for display. The simple pow(1/2.2)
    // approximation is used instead of the exact sRGB transfer function
    // (which has a linear segment near black) — the difference is negligible.
    color = pow(color, vec3(1.0 / 2.2));

    // ---- Vignette ----
    // Darkens the edges and corners of the frame, drawing the eye to the center.
    // Uses smoothstep for a gradual falloff. The smoothness parameter controls
    // how far from the edge the darkening begins — lower values push it further in.
    float vignette_intensity = composite.params2.x;
    if (vignette_intensity > 0.0) {
        float smoothness = composite.params2.y;
        vec2 vc = frag_uv - 0.5;
        float dist = length(vc);
        float vignette = smoothstep(smoothness, smoothness - 0.35, dist);
        color *= mix(1.0, vignette, vignette_intensity);
    }

    // ---- Film Grain ----
    // Animated noise that simulates the photosensitive grain in analog film.
    // Applied in gamma space (after tonemapping) because grain in real film
    // is a perceptual phenomenon that interacts with displayed brightness.
    // The grain is multiplicative and stronger in darker areas — real film
    // grain is more visible in shadows and mid-tones than in highlights.
    float grain_intensity = composite.params3.y;
    if (grain_intensity > 0.0) {
        float grain_time = composite.params3.z;  // Changes each frame for animation
        float noise = hash(frag_uv * 1000.0 + grain_time) * 2.0 - 1.0;  // [-1, 1]

        // Grain amount scales inversely with luminance (darker = more grain)
        float luminance = dot(color, vec3(0.2126, 0.7152, 0.0722));
        float grain_amount = grain_intensity * (1.0 - luminance * 0.5);
        color += color * noise * grain_amount;
    }

    out_color = vec4(color, 1.0);
}
