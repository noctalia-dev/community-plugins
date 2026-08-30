// @Title: Cyberpunk
// @Icon: cpu
// @Color: #d946ef
// @Tag: CYBER
// @Desc: Mix of high contrast and neon tones.

#version 300 es
precision highp float;

in vec2 v_texcoord;
out vec4 fragColor;
uniform sampler2D tex;

void main() {
    // 1. Modern color capture
    vec4 col = texture(tex, v_texcoord);

    // 2. Controlled desaturation (30%)
    // Calculate the gray and mix it with the original to avoid losing all the color
    float gray = dot(col.rgb, vec3(0.299, 0.587, 0.114));
    vec3 mixed = mix(col.rgb, vec3(gray), 0.3);

    // 3. Contrast boost (Mid-tone boost)
    // We use 0.5 as a pivot point: lights get lighter, darks get darker
    mixed = mix(vec3(0.5), mixed, 1.2);

    // 4. Final output
    fragColor = vec4(mixed, col.a);
}