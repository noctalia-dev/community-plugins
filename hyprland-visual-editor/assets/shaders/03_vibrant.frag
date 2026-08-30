// @Title: Vibrant
// @Icon: sun
// @Color: #facc15
// @Tag: SAT
// @Desc: Increases saturation and contrast.

#version 300 es
precision highp float;

in vec2 v_texcoord;
out vec4 fragColor;
uniform sampler2D tex;

void main() {
    // 1. Modern color capture
    vec4 col = texture(tex, v_texcoord);

    // 2. Current saturation calculation
    //We look for the difference between the strongest and weakest channel
    float max_val = max(col.r, max(col.g, col.b));
    float min_val = min(col.r, min(col.g, col.b));
    float sat = max_val - min_val;

    // 3. Standard luminance (Rec. 709)
    //We use modern coefficients for greater accuracy on digital displays:
    // $$L = 0.2126R + 0.7152G + 0.0722B$$
    float luma = dot(col.rgb, vec3(0.2126, 0.7152, 0.0722));

   //4. Vibrance Logic
    //Intensity: 0.8. The lower 'sat' is, the more 'amount' we will apply.
    float vibrance = 0.8;
    float amount = vibrance * (1.0 - sat);

    //We mix the luminance with the original color based on intelligent calculation
    vec3 result = mix(vec3(luma), col.rgb, 1.0 + amount);

    // 5. Exit
    fragColor = vec4(result, col.a);
}
