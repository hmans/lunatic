#version 450

// ============================================================================
// Shadow Map Fragment Shader — Lunatic Engine
// ============================================================================
//
// Writes fragment depth to the shadow atlas. The hardware depth test handles
// occlusion — we just need to output the depth value for the shadow comparison
// in the main scene shader's sampleShadowCascade().
//
// gl_FragCoord.z contains the depth in [0, 1] range from the light's
// orthographic projection. This gets compared against the scene fragment's
// reprojected depth to determine if it's in shadow.
// ============================================================================

layout(location = 0) out float out_depth;

void main() {
    out_depth = gl_FragCoord.z;
}
