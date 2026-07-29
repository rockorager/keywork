#version 450
layout(set=0,binding=0) uniform sampler2D tex;
layout(set=1,binding=0) uniform sampler3D calibration_lut;
layout(push_constant) uniform Push {
    vec2 target_size;
    vec2 texture_size;
    float swap_rb;
    float quantization_levels;
    layout(offset=32) vec4 color_matrix_0;
    vec4 color_matrix_1;
    vec4 color_matrix_2;
    vec4 transfer;
    vec4 output_transfer;
    vec4 transfer_aux;
} pc;
layout(location=0) in vec2 pixel;
layout(location=0) out vec4 out_color;

float dither(ivec2 coordinate) {
    const float matrix[16]=float[16](
         0.0,  8.0,  2.0, 10.0,
        12.0,  4.0, 14.0,  6.0,
         3.0, 11.0,  1.0,  9.0,
        15.0,  7.0, 13.0,  5.0
    );
    int index=(coordinate.y&3)*4+(coordinate.x&3);
    return (matrix[index]/16.0-0.46875)/pc.quantization_levels;
}

void main() {
    vec2 uv=pixel/pc.texture_size;
    vec4 linear=texture(tex,uv);
    float alpha=clamp(linear.a,0.0,1.0);
    vec3 straight=alpha>0.0 ? linear.rgb/alpha : vec3(0.0);
    float black=max(pc.transfer_aux.x,0.0);
    float white=max(pc.output_transfer.w,black+0.000001);
    vec3 relative=clamp((straight*pc.output_transfer.z-black)/(white-black),0.0,1.0);
    const float edge=33.0;
    vec3 coordinate=relative*((edge-1.0)/edge)+vec3(0.5/edge);
    vec3 encoded=texture(calibration_lut,coordinate).rgb*alpha;
    encoded=clamp(encoded+vec3(dither(ivec2(gl_FragCoord.xy))*alpha),vec3(0.0),vec3(alpha));
    vec4 color=vec4(encoded,alpha);
    out_color=pc.swap_rb>0.5 ? color.bgra : color;
}
