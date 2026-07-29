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
layout(location=3) flat in vec4 finish;
layout(location=5) flat in vec4 parameters;
layout(location=0) out vec4 out_color;

vec3 encodeSrgb(vec3 value) {
    vec3 positive=max(value,vec3(0.0));
    return mix(
        12.92*positive,
        1.055*pow(positive,vec3(1.0/2.4))-0.055,
        greaterThan(positive,vec3(0.0031308))
    );
}

vec3 decodeSrgb(vec3 value) {
    vec3 positive=max(value,vec3(0.0));
    return mix(
        positive/12.92,
        pow((positive+0.055)/1.055,vec3(2.4)),
        greaterThan(positive,vec3(0.04045))
    );
}

float stableNoise(uvec2 coordinate) {
    uint value=coordinate.x*0x9e3779b9u^coordinate.y*0x85ebca6bu;
    value^=value>>16;
    value*=0x7feb352du;
    value^=value>>15;
    value*=0x846ca68bu;
    value^=value>>16;
    return float(value&0xffffu)/65535.0-0.5;
}

void main() {
    vec2 q=(pixel-dest.xy)/dest.zw;
    vec2 coordinate=source.xy+q*source.zw;
    vec2 uv=coordinate/pc.texture_size;
    vec2 axial=vec2(parameters.x)/pc.texture_size;
    vec2 diagonal=axial*0.5;
    vec4 color=texture(tex,uv+vec2(-axial.x,0.0));
    color+=texture(tex,uv+vec2(axial.x,0.0));
    color+=texture(tex,uv+vec2(0.0,-axial.y));
    color+=texture(tex,uv+vec2(0.0,axial.y));
    color+=texture(tex,uv+vec2(-diagonal.x,-diagonal.y))*2.0;
    color+=texture(tex,uv+vec2( diagonal.x,-diagonal.y))*2.0;
    color+=texture(tex,uv+vec2(-diagonal.x, diagonal.y))*2.0;
    color+=texture(tex,uv+vec2( diagonal.x, diagonal.y))*2.0;
    color/=12.0;
    if (finish.y>0.5 && color.a>0.0) {
        vec3 perceptual=encodeSrgb(color.rgb/color.a);
        float luminance=dot(perceptual,vec3(0.2126,0.7152,0.0722));
        perceptual=mix(vec3(luminance),perceptual,parameters.z);
        perceptual+=finish.x-1.0;
        perceptual=(perceptual-0.5)*parameters.y+0.5;
        perceptual+=stableNoise(uvec2(ivec2(pixel)))*parameters.w;
        color.rgb=decodeSrgb(perceptual)*color.a;
    }
    out_color=color;
}
