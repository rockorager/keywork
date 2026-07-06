#version 450

layout(set = 0, binding = 0) uniform sampler2D atlas;

layout(location = 0) in vec2 frag_uv;
layout(location = 1) in vec4 frag_color;

layout(location = 0) out vec4 out_color;

void main() {
    // Both inputs are premultiplied: atlas texels (white-tinted coverage
    // masks or premultiplied color images) and the vertex color.
    out_color = frag_color * texture(atlas, frag_uv);
}
