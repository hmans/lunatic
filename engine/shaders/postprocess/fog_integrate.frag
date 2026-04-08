#version 450

// ============================================================================
// Volumetric Fog Integration — Lunatic Engine
// ============================================================================
//
// Front-to-back accumulation of the froxel volume into a 2D fog texture.
// Each pixel marches through all Z slices of its froxel column, accumulating
// in-scattered light and transmittance using Beer-Lambert extinction.
//
// Output:
//   .rgb = accumulated in-scattered fog color (HDR, pre-tonemapped)
//   .a   = transmittance (1.0 = clear, 0.0 = fully fogged)
//
// Applied in the composite shader: final = scene * transmittance + fog_color
//
// Uses the scene depth buffer (HDR alpha) to stop accumulation at the first
// opaque surface — fog behind geometry doesn't contribute.
// ============================================================================

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_fog;

// Froxel volume as a 2D texture: width = froxel_W * froxel_H, height = froxel_D
// Each row is one depth slice, each pixel within a row is one XY froxel.
// Avoids fragment shader storage buffer binding issues on Metal.
layout(set = 2, binding = 0) uniform sampler2D froxel_tex;

// Scene depth (HDR alpha = linear camera distance)
layout(set = 2, binding = 1) uniform sampler2D scene_tex;

layout(set = 3, binding = 0) uniform IntegrateParams {
    vec4 volume_params;  // x = froxel_w, y = froxel_h, z = depth_slices, w = near
    vec4 depth_params;   // x = far, y = tex_width (W*H), z = tex_height (D), w = frame_count
};

// ---------------------------------------------------------------------------
// Interleaved Gradient Noise (Jimenez, 2014)
// ---------------------------------------------------------------------------
// Produces a well-distributed scalar in [0, 1) per pixel. Used to jitter the
// depth sampling within each froxel slice, which breaks up the visible banding
// that occurs when all pixels sample the exact same slice boundaries.
// The frame offset animates the jitter temporally, further reducing structured
// artifacts (banding → noise → invisible with temporal integration).

float interleavedGradientNoise(vec2 pixel, float frame) {
    pixel += frame * vec2(47.0, 17.0);
    return fract(52.9829189 * fract(0.06711056 * pixel.x + 0.00583715 * pixel.y));
}

void main() {
    int W = int(volume_params.x);
    int H = int(volume_params.y);
    int D = int(volume_params.z);
    float near = volume_params.w;
    float far = depth_params.x;
    float tex_w = depth_params.y;
    float tex_h = depth_params.z;

    // Per-pixel jitter to break up depth-slice banding.
    // Each pixel offsets its depth sampling by a different fraction of a slice,
    // so slice boundaries land at different depths across the screen.
    // This converts coherent bands into high-frequency noise that is
    // imperceptible at display resolution.
    float jitter = interleavedGradientNoise(gl_FragCoord.xy, depth_params.w);

    // Map screen UV to froxel XY
    int ix = clamp(int(frag_uv.x * float(W)), 0, W - 1);
    int iy = clamp(int(frag_uv.y * float(H)), 0, H - 1);
    int pixel_x = iy * W + ix;  // column within the 2D texture row

    // Scene depth at this pixel (stop accumulation at opaque surfaces)
    float scene_depth = texture(scene_tex, frag_uv).a;

    // Front-to-back accumulation with per-pixel jittered depth sampling.
    // The jitter offsets the evaluation point within each slice by [0, 1) slices,
    // effectively randomizing where slice boundaries fall per pixel.
    vec3 accum_scatter = vec3(0.0);
    float accum_transmittance = 1.0;

    for (int z = 0; z < D; z++) {
        // Jittered depth: shift sampling point within each slice
        float z_norm = (float(z) + jitter) / float(D);
        float slice_depth = near * pow(far / near, z_norm);

        // Stop at scene geometry
        if (slice_depth > scene_depth) break;

        // Sample froxel from 2D texture: x = pixel_x, y = z
        // The LINEAR sampler on froxel_tex provides interpolation between
        // adjacent Z slices when the jitter shifts the sample point, giving
        // additional smoothing beyond just the spatial jitter.
        vec2 tex_uv = vec2((float(pixel_x) + 0.5) / tex_w, (float(z) + jitter) / tex_h);
        vec4 froxel = texture(froxel_tex, tex_uv);

        float slice_transmittance = exp(-froxel.a);
        accum_scatter += froxel.rgb * accum_transmittance;
        accum_transmittance *= slice_transmittance;

        if (accum_transmittance < 0.01) break;
    }

    out_fog = vec4(accum_scatter, accum_transmittance);
}
