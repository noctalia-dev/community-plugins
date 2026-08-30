// @Title: Paper
// @Icon: file-text
// @Color: #fdba74
// @Tag: READ
// @Desc: Soft sepia tone for prolonged reading.

#version 300 es
precision highp float;

in vec2 v_texcoord;
out vec4 fragColor;
uniform sampler2D tex;

// Noise function (Still works the same at 300 es)
float rand(vec2 co){
    return fract(sin(dot(co.xy ,vec2(12.9898,78.233))) * 43758.5453);
}

void main() {
    // 1. Sampling (texture instead of texture2D)
    vec4 color = texture(tex, v_texcoord);

    // 2. Grayscale (Standard luminance)
    float gray = dot(color.rgb, vec3(0.299, 0.587, 0.114));

    // 3. Sepia/paper tint
    // Multiply the gray by a vector that leans towards yellow/cream
    vec3 sepia = vec3(gray) * vec3(1.0, 0.95, 0.82);

    // 4. Add noise (paper grain)
    // The noise is added to the final color to give that textured feel
    float noise = (rand(v_texcoord) - 0.5) * 0.05;

    // 5. Final output
    fragColor = vec4(sepia + noise, color.a);
}