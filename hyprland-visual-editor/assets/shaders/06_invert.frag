// @Title: Inverted
// @Icon: repeat
// @Color: #ffffff
// @Tag: INV
// @Desc: Inverts the colors (High Contrast Mode).

#version 300 es
precision highp float;

in vec2 v_texcoord;        // Before: varying
out vec4 fragColor;        // Before: gl_FragColor (Now we define it ourselves!)
uniform sampler2D tex;

void main() {
    // Before: texture2D -> Now: texture
    vec4 pixColor = texture(tex, v_texcoord);

    // The mathematical logic DOES NOT change, just the "plumbing"
    vec3 inverted = 1.0 - pixColor.rgb;

    fragColor = vec4(inverted, pixColor.a);
}