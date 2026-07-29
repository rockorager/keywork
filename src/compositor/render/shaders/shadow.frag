#version 450
// Adapted from SceneFX's MIT-licensed analytic rounded-box shadow shader.
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
layout(location=3) flat in vec4 color;
layout(location=4) flat in vec4 rounded;
layout(location=5) flat in vec4 parameters;
layout(location=0) out vec4 out_color;
float gaussian(float value,float sigma) {
    const float pi=3.141592653589793;
    return exp(-(value*value)/(2.0*sigma*sigma))/(sqrt(2.0*pi)*sigma);
}
float erfApprox(float value) {
    float s=sign(value),a=abs(value);
    float denominator=1.0+(0.278393+(0.230389+0.078108*a*a)*a)*a;
    denominator*=denominator;
    return s-s/(denominator*denominator);
}
float roundedBoxShadowX(float x,float y,float sigma,float radius,vec2 half_size) {
    float delta=min(half_size.y-radius-abs(y),0.0);
    float curved=half_size.x-radius+sqrt(max(0.0,radius*radius-delta*delta));
    vec2 integral=0.5+0.5*vec2(erfApprox((x-curved)*(sqrt(0.5)/sigma)),erfApprox((x+curved)*(sqrt(0.5)/sigma)));
    return integral.y-integral.x;
}
float roundedBoxShadow(vec2 lower,vec2 upper,vec2 point,float sigma,float radius) {
    vec2 center=(lower+upper)*0.5;
    vec2 half_size=(upper-lower)*0.5;
    point-=center;
    float low=point.y-half_size.y;
    float high=point.y+half_size.y;
    float start=clamp(-3.0*sigma,low,high);
    float end=clamp(3.0*sigma,low,high);
    float step=(end-start)*0.25;
    float y=start+step*0.5;
    float coverage=0.0;
    for (int i=0;i<4;i++) {
        coverage+=roundedBoxShadowX(point.x,point.y-y,sigma,radius,half_size)*gaussian(y,sigma)*step;
        y+=step;
    }
    return coverage;
}
float roundedRectCoverage(vec2 point,vec4 rect,float radius) {
    vec2 q=abs(point-(rect.xy+rect.zw*0.5))-(rect.zw*0.5-vec2(radius));
    float distance=length(max(q,vec2(0)))+min(max(q.x,q.y),0.0)-radius;
    return clamp(0.5-distance,0.0,1.0);
}
void main() {
    float cutout=parameters.w>0.5 ? 1.0-roundedRectCoverage(pixel,dest,parameters.z) : 1.0;
    if (cutout<=0.0) discard;
    float coverage=parameters.y>0.0 ? roundedBoxShadow(rounded.xy,rounded.xy+rounded.zw,pixel,parameters.y*0.5,parameters.x) : roundedRectCoverage(pixel,rounded,parameters.x);
    vec4 shaded=color*coverage;
    shaded*=cutout;
    out_color=shaded;
}
