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
layout(location=0) in vec4 in_dest;
layout(location=1) in vec4 in_source;
layout(location=2) in vec4 in_clip;
layout(location=3) in vec4 in_color;
layout(location=4) in vec4 in_rounded;
layout(location=5) in vec4 in_parameters;
layout(location=0) out vec2 pixel;
layout(location=1) flat out vec4 dest;
layout(location=2) flat out vec4 source;
layout(location=3) flat out vec4 color;
layout(location=4) flat out vec4 rounded;
layout(location=5) flat out vec4 parameters;
layout(location=6) out vec2 coordinate;

vec2 mapToTexture(vec2 transformed) {
    vec2 mapped;
    switch (int(in_parameters.y)) {
        case 1: mapped=vec2(transformed.y,pc.texture_size.y-transformed.x); break;
        case 2: mapped=pc.texture_size-transformed; break;
        case 3: mapped=vec2(pc.texture_size.x-transformed.y,transformed.x); break;
        case 4: mapped=vec2(pc.texture_size.x-transformed.x,transformed.y); break;
        case 5: mapped=pc.texture_size-transformed.yx; break;
        case 6: mapped=vec2(transformed.x,pc.texture_size.y-transformed.y); break;
        case 7: mapped=transformed.yx; break;
        default: mapped=transformed; break;
    }
    if (in_parameters.z>0.5) mapped.y=pc.texture_size.y-mapped.y;
    return mapped;
}

void main() {
    vec2 q=vec2(float(gl_VertexIndex&1),float((gl_VertexIndex>>1)&1));
    vec2 pos=in_clip.xy+q*in_clip.zw;
    vec2 destination_q=(pos-in_dest.xy)/in_dest.zw;
    gl_Position=vec4(pos/pc.target_size*2.0-1.0,0,1);
    pixel=pos;
    dest=in_dest;
    source=in_source;
    color=in_color;
    rounded=in_rounded;
    parameters=in_parameters;
    coordinate=mapToTexture(in_source.xy+destination_q*in_source.zw);
}
