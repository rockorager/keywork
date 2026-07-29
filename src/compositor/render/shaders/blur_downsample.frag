#version 450
layout(set=0,binding=0) uniform sampler2D tex;
layout(push_constant) uniform Push {
    vec2 target_size;
    vec2 texture_size;
    float swap_rb;
    layout(offset=32) vec4 color_matrix_0;
    vec4 color_matrix_1;
    vec4 color_matrix_2;
    vec4 transfer;
    vec4 output_transfer;
    vec4 transfer_aux;
} pc;
layout(location=0) in vec2 pixel;
layout(location=1) flat in vec4 dest;
layout(location=2) flat in vec4 source;
layout(location=5) flat in vec4 parameters;
layout(location=0) out vec4 out_color;
void main() {
    vec2 q=(pixel-dest.xy)/dest.zw;
    vec2 coordinate=source.xy+q*source.zw;
    vec2 uv=coordinate/pc.texture_size;
    vec2 offset=vec2(parameters.x)/pc.texture_size;
    vec4 color=texture(tex,uv)*4.0;
    color+=texture(tex,uv+vec2(-offset.x,-offset.y));
    color+=texture(tex,uv+vec2( offset.x,-offset.y));
    color+=texture(tex,uv+vec2(-offset.x, offset.y));
    color+=texture(tex,uv+vec2( offset.x, offset.y));
    out_color=color/8.0;
}
