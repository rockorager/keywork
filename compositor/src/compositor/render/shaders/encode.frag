#version 450
layout(set=0,binding=0) uniform sampler2D tex;
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

float encodeGamma22(float value) {
    return pow(clamp(value,0.0,1.0),1.0/2.2);
}

float encodeComponent(float value) {
    int transfer=int(pc.output_transfer.x+0.5);
    float black=max(pc.transfer_aux.x,0.0);
    float white=max(pc.output_transfer.w,black+0.000001);
    float relative=(value*pc.output_transfer.z-black)/(white-black);
    if (transfer==1) return encodeGamma22(relative);
    if (transfer==2) {
        float linear=max(relative,0.0);
        return linear<=0.0031308 ? 12.92*linear : 1.055*pow(linear,1.0/2.4)-0.055;
    }
    if (transfer==3) {
        float black_root=pow(black,1.0/2.4);
        float denominator=pow(white,1.0/2.4)-black_root;
        float a=pow(denominator,2.4);
        float b=black_root/denominator;
        float nits=max(value,0.0)*pc.output_transfer.z;
        return pow(max(nits/a,0.0),1.0/2.4)-b;
    }
    if (transfer==4) {
        return sign(relative)*pow(abs(relative),1.0/pc.output_transfer.y);
    }
    if (transfer==5) {
        const float m1=2610.0/16384.0;
        const float m2=2523.0/32.0;
        const float c1=3424.0/4096.0;
        const float c2=2413.0/128.0;
        const float c3=2392.0/128.0;
        float normalized=clamp((value*pc.output_transfer.z-black)/10000.0,0.0,1.0);
        float p=pow(normalized,m1);
        return pow((c1+c2*p)/(1.0+c3*p),m2);
    }
    return value;
}

vec3 encodeHlg(vec3 value) {
    const float a=0.17883277;
    const float b=0.28466892;
    const float c=0.55991073;
    vec3 display=max(value*pc.output_transfer.z,vec3(0.0));
    float display_luminance=max(dot(pc.transfer_aux.yzw,display),0.0);
    float scene_luminance=pow(display_luminance/pc.output_transfer.w,1.0/1.2);
    float gain=pc.output_transfer.w*pow(scene_luminance,0.2);
    vec3 scene=gain>0.000001 ? display/gain : vec3(0.0);
    return mix(
        sqrt(3.0*scene),
        a*log(max(12.0*scene-b,vec3(0.000001)))+c,
        greaterThan(scene,vec3(1.0/12.0))
    );
}

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
    vec3 encoded=(int(pc.output_transfer.x+0.5)==6 ? encodeHlg(straight) : vec3(
            encodeComponent(straight.r),
            encodeComponent(straight.g),
            encodeComponent(straight.b)
        ))*alpha;
    encoded=clamp(encoded+vec3(dither(ivec2(gl_FragCoord.xy))*alpha),vec3(0.0),vec3(alpha));
    vec4 color=vec4(encoded,alpha);
    out_color=pc.swap_rb>0.5 ? color.bgra : color;
}
