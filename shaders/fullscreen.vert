#version 450

// Fullscreen triangle from vertex ID — no vertex buffer needed.
// Covers clip space with a single oversized triangle (vertices at -1,-1 / 3,-1 / -1,3).

layout(location = 0) out vec2 frag_uv;

void main() {
    // Generate triangle that covers the full screen
    frag_uv = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
    gl_Position = vec4(frag_uv * 2.0 - 1.0, 0.0, 1.0);
    frag_uv.y = 1.0 - frag_uv.y; // Flip Y for texture sampling
}
