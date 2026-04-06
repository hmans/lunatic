#version 450

// ============================================================================
// Fullscreen Triangle Vertex Shader — Lunatic Engine
// ============================================================================
//
// Generates a single triangle that covers the entire screen using only the
// vertex ID (gl_VertexIndex). No vertex buffer needed — draw with 3 vertices.
//
// The trick: a triangle with vertices at (-1,-1), (3,-1), (-1,3) in clip space
// fully covers the [-1,1] viewport. The GPU clips the excess, and every pixel
// gets exactly one fragment (no overdraw from a quad's diagonal).
//
// UV output is [0,1] with Y flipped so (0,0) = top-left, matching texture
// coordinate conventions for sampling render targets.
//
// Used by all post-processing passes (bloom, DoF, composite, lens flare).
// ============================================================================

layout(location = 0) out vec2 frag_uv;

void main() {
    // Bit tricks: vertex 0 -> (0,0), vertex 1 -> (2,0), vertex 2 -> (0,2)
    frag_uv = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
    gl_Position = vec4(frag_uv * 2.0 - 1.0, 0.0, 1.0);
    frag_uv.y = 1.0 - frag_uv.y; // Flip Y for texture sampling
}
