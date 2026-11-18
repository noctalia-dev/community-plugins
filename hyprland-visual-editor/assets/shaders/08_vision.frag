// @Title: Night Vision
// @Icon: eye
// @Color: #4ade80
// @Tag: NIGHT
// @Desc: High contrast green phosphor filter.

#version 300 es
precision highp float;

in vec2 v_texcoord;
out vec4 fragColor;
uniform sampler2D tex;

void main() {
    // 1. Modern sampling
    vec4 col = texture(tex, v_texcoord);

    // 2. Luminance calculation
    // Multiply colors by human eye sensitivity
    float lum = dot(col.rgb, vec3(0.299, 0.587, 0.114));

    // 3. Color reconstruction
    // R = 0.0, G = lum, B = 0.0, A = original
    fragColor = vec4(0.0, lum, 0.0, col.a);
}