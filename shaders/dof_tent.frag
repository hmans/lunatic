#version 450

// 3x3 tent filter to smooth bokeh gather noise before upsampling.
// Weights: 1 2 1 / 2 4 2 / 1 2 1  (sum = 16)

layout(location = 0) in vec2 frag_uv;
layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D source_tex;

layout(set = 3, binding = 0) uniform TentParams {
    vec4 params; // .xy = texel size
} tent;

void main() {
    vec2 t = tent.params.xy;

    vec4 a = texture(source_tex, frag_uv + vec2(-t.x, -t.y));
    vec4 b = texture(source_tex, frag_uv + vec2( 0.0, -t.y));
    vec4 c = texture(source_tex, frag_uv + vec2( t.x, -t.y));
    vec4 d = texture(source_tex, frag_uv + vec2(-t.x,  0.0));
    vec4 e = texture(source_tex, frag_uv);
    vec4 f = texture(source_tex, frag_uv + vec2( t.x,  0.0));
    vec4 g = texture(source_tex, frag_uv + vec2(-t.x,  t.y));
    vec4 h = texture(source_tex, frag_uv + vec2( 0.0,  t.y));
    vec4 i = texture(source_tex, frag_uv + vec2( t.x,  t.y));

    out_color = ((a + c + g + i) + (b + d + f + h) * 2.0 + e * 4.0) / 16.0;
}
