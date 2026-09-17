#version 450

layout(location = 0) out vec4 out_color;

// safety: the shadow map is a color target with the fragment's depth packed into
// it, because a depth attachment cannot be sampled again in the same frame
vec4 packDepth(float depth) {
    vec4 enc = fract(depth * vec4(1.0, 255.0, 65025.0, 16581375.0));
    enc -= enc.yzww * vec4(1.0 / 255.0, 1.0 / 255.0, 1.0 / 255.0, 0.0);
    return enc;
}

void main() {
    out_color = packDepth(gl_FragCoord.z);
}
