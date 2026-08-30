//@Title: Sharpness
//@Icon: aperture
//@Color: #22d3ee
//@Tag: SHARP
//@Desc: Enhances borders and texts (Sharpen).

#version 300 es
precision highp float;

in vec2 v_texcoord;
out vec4 fragColor;
uniform sampler2D tex;

void main() {
   //1. We take the central pixel (Modern Sampling)
    vec4 center = texture(tex, v_texcoord);

    //2. We define the displacement
    //Note: 0.0005 is ideal for 1080p.
    //If you use 4K, you might need to raise it to 0.001.
    float offset = 0.0005;

    //3. We sample adjacent (texture instead of texture2D)
    vec3 up    = texture(tex, v_texcoord + vec2(0.0, offset)).rgb;
    vec3 down  = texture(tex, v_texcoord - vec2(0.0, offset)).rgb;
    vec3 left  = texture(tex, v_texcoord - vec2(offset, 0.0)).rgb;
    vec3 right = texture(tex, v_texcoord + vec2(offset, 0.0)).rgb;

    //4. Kernel de enfoque (Laplacian Sharpening)
    //We multiply the center by 5 and subtract the cross of neighbors.
    //This amplifies contrast differences at the edges.
    vec3 result = center.rgb * 5.0 - (up + down + left + right);

    //5. Outlet with safety cutout (clamp)
    //The clamp is vital here because subtraction can give negative values
    fragColor = vec4(clamp(result, 0.0, 1.0), center.a);
}
