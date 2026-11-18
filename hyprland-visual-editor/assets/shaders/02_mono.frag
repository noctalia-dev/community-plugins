// @Title: Monochrome
// @Icon: circle-half
// @Color: #94a3b8
// @Tag: BW
// @Desc: Gray scale for maximum concentration.

#version 300 es
precision highp float;

in vec2 v_texcoord;
out vec4 fragColor;
uniform sampler2D tex;

void main() {
    vec4 c = texture(tex, v_texcoord);

    //Standard luminance formula (NTSC/PAL)
    //The human eye perceives green as brighter than blue,
    //that's why we use these weights:
    float gray = dot(c.rgb, vec3(0.299, 0.587, 0.114));

    //We create a new color using the gray value for R, G and B
    fragColor = vec4(vec3(gray), c.a);
}
