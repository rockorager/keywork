#version 450
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
layout(location=3) flat in vec4 color;
layout(location=0) out vec4 out_color;
void main() { out_color=color; }
