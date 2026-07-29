#version 450
#ifdef KEYWORK_MANUAL_YCBCR
layout(set=0,binding=0) uniform sampler2D luma_plane;
layout(set=0,binding=1) uniform sampler2D chroma_plane;
#else
layout(set=0,binding=0) uniform sampler2D tex;
#endif
#ifdef KEYWORK_CROSSFADE
layout(set=1,binding=0) uniform sampler2D new_tex;
#endif
#ifdef KEYWORK_BACKDROP
layout(set=1,binding=0) uniform sampler2D backdrop_tex;
#define KEYWORK_NEAREST
#endif
layout(push_constant) uniform Push {
    vec2 target_size;
    vec2 texture_size;
    float swap_rb;
    float quantization_levels;
    vec2 ycbcr_coefficients;
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
layout(location=3) flat in vec4 instance_color;
layout(location=4) flat in vec4 rounded;
layout(location=5) flat in vec4 parameters;
layout(location=6) in vec2 coordinate;
layout(location=0) out vec4 out_color;

float decodeComponent(float value) {
#ifdef KEYWORK_TRANSFER_GAMMA22
    return pow(max(value,0.0),2.2);
#else
    int transfer=int(pc.transfer.x+0.5);
    if (transfer==0) return value;
    if (transfer==1) return pow(max(value,0.0),2.2);
    if (transfer==2) return value<=0.04045 ? value/12.92 : pow((value+0.055)/1.055,2.4);
    if (transfer==3) {
        float black=max(pc.transfer.y,0.0);
        float white=max(pc.transfer.w,black+0.000001);
        float black_root=pow(black,1.0/2.4);
        float denominator=pow(white,1.0/2.4)-black_root;
        float a=pow(denominator,2.4);
        float b=black_root/denominator;
        return a*pow(max(value+b,0.0),2.4);
    }
    if (transfer==4) return sign(value)*pow(abs(value),pc.transfer.y);
    if (transfer==5) {
        const float m1=2610.0/16384.0;
        const float m2=2523.0/32.0;
        const float c1=3424.0/4096.0;
        const float c2=2413.0/128.0;
        const float c3=2392.0/128.0;
        float p=pow(max(value,0.0),1.0/m2);
        return 10000.0*pow(max(p-c1,0.0)/max(c2-c3*p,0.000001),1.0/m1)+pc.transfer_aux.x;
    }
    if (transfer==6) {
        const float a=0.17883277;
        const float b=0.28466892;
        const float c=0.55991073;
        float scene=value<=0.5 ? value*value/3.0 : (exp((value-c)/a)+b)/12.0;
        return scene;
    }
    return value;
#endif
}

vec3 toneMapHdr(vec3 nits) {
    float reference_nits=pc.transfer.z;
    float peak_nits=max(pc.transfer.w,reference_nits+0.001);
    vec3 relative=max(nits,vec3(0.0))/reference_nits;
    float relative_luminance=max(dot(pc.transfer_aux.yzw,relative),0.0);
    float output_peak=max(pc.output_transfer.w/pc.output_transfer.z,1.0);
    float input_peak=max(peak_nits/reference_nits,1.01);
    float mapped_luminance=relative_luminance;
    if (input_peak>output_peak) {
        float knee=min(1.0,0.8*output_peak);
        if (relative_luminance>knee) {
            mapped_luminance=knee+(output_peak-knee)*
                log(relative_luminance/knee)/log(input_peak/knee);
            mapped_luminance=min(mapped_luminance,output_peak);
        }
    }
    vec3 mapped=relative_luminance>0.000001 ?
        relative*(mapped_luminance/relative_luminance) : vec3(0.0);
    float mapped_peak=max(mapped.r,max(mapped.g,mapped.b));
    return mapped_peak>output_peak ? mapped*(output_peak/mapped_peak) : mapped;
}

vec3 compressGamut(vec3 color) {
    if (pc.color_matrix_0.w<=0.0) return color;
#ifndef KEYWORK_TRANSFER_GAMMA22
    if (int(pc.transfer.x+0.5)>=5 && int(pc.output_transfer.x+0.5)>=5) return color;
#endif
    vec3 luminance_weights=vec3(
        pc.color_matrix_0.w,
        pc.color_matrix_1.w,
        pc.color_matrix_2.w
    );
    float output_peak=max(pc.output_transfer.w/pc.output_transfer.z,1.0);
    float luminance=clamp(dot(luminance_weights,color),0.0,output_peak);
    vec3 chroma=color-vec3(luminance);
    float boundary=1000000.0;
    if (chroma.r>0.000001) boundary=min(boundary,(output_peak-luminance)/chroma.r);
    else if (chroma.r< -0.000001) boundary=min(boundary,-luminance/chroma.r);
    if (chroma.g>0.000001) boundary=min(boundary,(output_peak-luminance)/chroma.g);
    else if (chroma.g< -0.000001) boundary=min(boundary,-luminance/chroma.g);
    if (chroma.b>0.000001) boundary=min(boundary,(output_peak-luminance)/chroma.b);
    else if (chroma.b< -0.000001) boundary=min(boundary,-luminance/chroma.b);
    float saturation=1.0/max(boundary,0.000001);
    const float threshold=0.8;
    if (saturation<=threshold) return color;
    float compressed=threshold+(1.0-threshold)*
        (1.0-exp(-(saturation-threshold)/(1.0-threshold)));
    return vec3(luminance)+chroma*(compressed/saturation);
}

vec3 decodeColor(vec3 electrical) {
    vec3 optical=vec3(
        decodeComponent(electrical.r),
        decodeComponent(electrical.g),
        decodeComponent(electrical.b)
    );
#ifdef KEYWORK_TRANSFER_GAMMA22
    optical=((pc.transfer.w-pc.transfer_aux.x)*optical+pc.transfer_aux.x)/pc.transfer.z;
#else
    int transfer=int(pc.transfer.x+0.5);
    if (transfer==0) {}
    else if (transfer==5) {
        if (int(pc.output_transfer.x+0.5)>=5) optical/=pc.transfer.z;
        else optical=toneMapHdr(optical);
    }
    else if (transfer==6) {
        float scene_luminance=max(dot(pc.transfer_aux.yzw,max(optical,vec3(0.0))),0.0);
        optical=pc.transfer.y*pow(scene_luminance,0.2)*optical;
        if (int(pc.output_transfer.x+0.5)>=5) optical/=pc.transfer.z;
        else optical=toneMapHdr(optical);
    }
    else if (transfer==3) optical/=pc.transfer.z;
    else optical=((pc.transfer.w-pc.transfer_aux.x)*optical+pc.transfer_aux.x)/pc.transfer.z;
#endif
    return compressGamut(vec3(
        dot(pc.color_matrix_0.xyz,optical),
        dot(pc.color_matrix_1.xyz,optical),
        dot(pc.color_matrix_2.xyz,optical)
    ));
}

#ifdef KEYWORK_MANUAL_YCBCR
vec4 sampleSource(vec2 coordinate) {
    float y_sample=texture(luma_plane,coordinate/pc.texture_size).r;
    float horizontal_offset=pc.swap_rb>4.5 ? 0.5 : 0.0;
    vec2 chroma_coordinate=(coordinate+vec2(0.5)-vec2(horizontal_offset,1.0))/
        pc.texture_size;
    vec2 cbcr_sample=texture(chroma_plane,chroma_coordinate).rg;
    float levels=abs(pc.quantization_levels);
    float code_scale=(levels+1.0)/256.0;
    float y;
    vec2 cbcr;
    if (pc.quantization_levels<0.0) {
        y=(y_sample*levels-16.0*code_scale)/(219.0*code_scale);
        cbcr=(cbcr_sample*levels-vec2(128.0*code_scale))/(224.0*code_scale);
    } else {
        y=y_sample;
        cbcr=cbcr_sample-vec2((levels+1.0)/(2.0*levels));
    }
    float kr=pc.ycbcr_coefficients.x;
    float kb=pc.ycbcr_coefficients.y;
    float kg=1.0-kr-kb;
    return vec4(
        y+2.0*(1.0-kr)*cbcr.y,
        y-2.0*(kb*(1.0-kb)*cbcr.x+kr*(1.0-kr)*cbcr.y)/kg,
        y+2.0*(1.0-kb)*cbcr.x,
        1.0
    );
}
#endif

vec2 mapToTexture(vec2 transformed) {
    vec2 coordinate;
    switch (int(parameters.y)) {
        case 1: coordinate=vec2(transformed.y,pc.texture_size.y-transformed.x); break;
        case 2: coordinate=pc.texture_size-transformed; break;
        case 3: coordinate=vec2(pc.texture_size.x-transformed.y,transformed.x); break;
        case 4: coordinate=vec2(pc.texture_size.x-transformed.x,transformed.y); break;
        case 5: coordinate=pc.texture_size-transformed.yx; break;
        case 6: coordinate=vec2(transformed.x,pc.texture_size.y-transformed.y); break;
        case 7: coordinate=transformed.yx; break;
        default: coordinate=transformed; break;
    }
    if (parameters.z>0.5) coordinate.y=pc.texture_size.y-coordinate.y;
    return coordinate;
}

#ifdef KEYWORK_CATMULL_ROM
vec4 sampleCatmullRom(vec2 coordinate,vec2 lower,vec2 upper) {
    vec2 center=floor(coordinate-0.5)+0.5;
    vec2 fraction=coordinate-center;
    vec2 w0=fraction*(-0.5+fraction*(1.0-0.5*fraction));
    vec2 w1=1.0+fraction*fraction*(1.5*fraction-2.5);
    vec2 w2=fraction*(0.5+fraction*(2.0-1.5*fraction));
    vec2 w3=fraction*fraction*(0.5*fraction-0.5);
    vec2 w12=w1+w2;
    vec2 p0=clamp(center-1.0,lower,upper);
    vec2 p12=clamp(center+w2/w12,lower,upper);
    vec2 p3=clamp(center+2.0,lower,upper);
    vec2 inverse_size=1.0/pc.texture_size;
    p0*=inverse_size;
    p12*=inverse_size;
    p3*=inverse_size;
    vec4 color=
        texture(tex,vec2(p0.x,p0.y))*(w0.x*w0.y)+
        texture(tex,vec2(p12.x,p0.y))*(w12.x*w0.y)+
        texture(tex,vec2(p3.x,p0.y))*(w3.x*w0.y)+
        texture(tex,vec2(p0.x,p12.y))*(w0.x*w12.y)+
        texture(tex,vec2(p12.x,p12.y))*(w12.x*w12.y)+
        texture(tex,vec2(p3.x,p12.y))*(w3.x*w12.y)+
        texture(tex,vec2(p0.x,p3.y))*(w0.x*w3.y)+
        texture(tex,vec2(p12.x,p3.y))*(w12.x*w3.y)+
        texture(tex,vec2(p3.x,p3.y))*(w3.x*w3.y);
    color=clamp(color,vec4(0.0),vec4(1.0));
    color.rgb=min(color.rgb,vec3(color.a));
    return color;
}
#endif

#ifdef KEYWORK_AREA
void areaPairs(float start,float end,out vec4 positions,out vec4 weights) {
    float base=floor(start);
    for (int pair=0;pair<4;pair++) {
        float first=base+2.0*float(pair);
        float first_weight=clamp(min(end,first+1.0)-max(start,first),0.0,1.0);
        float second_weight=clamp(min(end,first+2.0)-max(start,first+1.0),0.0,1.0);
        float weight=first_weight+second_weight;
        positions[pair]=first+0.5+(weight>0.0 ? second_weight/weight : 0.0);
        weights[pair]=weight;
    }
}

vec4 sampleArea(vec2 coordinate) {
    vec2 footprint=abs(source.zw/dest.zw);
    vec2 radius=clamp(footprint*0.5,vec2(0.5),vec2(3.5));
    vec2 start=max(coordinate-radius,source.xy);
    vec2 end=min(coordinate+radius,source.xy+source.zw);
    vec4 x_positions;
    vec4 x_weights;
    vec4 y_positions;
    vec4 y_weights;
    areaPairs(start.x,end.x,x_positions,x_weights);
    areaPairs(start.y,end.y,y_positions,y_weights);
    vec4 color=vec4(0.0);
    float total_weight=0.0;
    for (int y=0;y<4;y++) {
        for (int x=0;x<4;x++) {
            float weight=x_weights[x]*y_weights[y];
            if (weight<=0.0) continue;
            vec2 sample_coordinate=mapToTexture(vec2(x_positions[x],y_positions[y]));
            color+=texture(tex,sample_coordinate/pc.texture_size)*weight;
            total_weight+=weight;
        }
    }
    return color/max(total_weight,0.000001);
}
#endif

void main() {
#ifdef KEYWORK_AREA
    vec2 q=(pixel-dest.xy)/dest.zw;
    vec2 transformed=source.xy+q*source.zw;
#endif
#ifdef KEYWORK_MANUAL_YCBCR
    vec4 color=sampleSource(coordinate);
#else
#ifdef KEYWORK_NEAREST
    ivec2 texel=clamp(ivec2(floor(coordinate)),ivec2(0),textureSize(tex,0)-ivec2(1));
    vec4 color=texelFetch(tex,texel,0);
#elif defined(KEYWORK_CATMULL_ROM)
    vec2 first=mapToTexture(source.xy);
    vec2 last=mapToTexture(source.xy+source.zw);
    vec2 lower=min(first,last)+0.5;
    vec2 upper=max(max(first,last)-0.5,lower);
    vec4 color=sampleCatmullRom(coordinate,lower,upper);
#elif defined(KEYWORK_AREA)
    vec4 color=sampleArea(transformed);
#else
    vec2 uv=coordinate/pc.texture_size;
    vec4 color=texture(tex,uv);
#endif
#ifdef KEYWORK_CROSSFADE
    vec2 q=(pixel-dest.xy)/dest.zw;
    vec2 new_coordinate=instance_color.xy+q*instance_color.zw;
    color=mix(color,texture(new_tex,new_coordinate/vec2(textureSize(new_tex,0))),parameters.w);
#endif
    if (pc.swap_rb>0.5) color=color.bgra;
#endif
#ifndef KEYWORK_CROSSFADE
    vec3 straight=color.a>0.0 ? color.rgb/color.a : vec3(0.0);
    color.rgb=decodeColor(straight)*color.a;
    color*=parameters.w;
#endif
    float coverage=1.0;
    if (parameters.x>0.0) {
        vec2 center=clamp(pixel,rounded.xy+vec2(parameters.x),rounded.xy+rounded.zw-vec2(parameters.x));
        coverage=clamp(parameters.x+0.5-distance(pixel,center),0.0,1.0);
    }
#ifdef KEYWORK_BACKDROP
    ivec2 backdrop_size=textureSize(backdrop_tex,0);
    float backdrop_scale=all(equal(vec2(backdrop_size),pc.target_size)) ? 1.0 : 2.0;
    vec4 backdrop=texture(backdrop_tex,(pixel/backdrop_scale)/vec2(backdrop_size));
    color=color*coverage+backdrop*(coverage*(1.0-coverage*color.a));
#else
    color*=coverage;
#endif
    out_color=color;
}
