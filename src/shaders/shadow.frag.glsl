#version 450

layout(location = 0) out vec4 out_color;

// safety: the shadow map is a depth target, so the pass writes the fragment's depth where
// depth always goes and this shader has nothing to pack. A pipeline needs a fragment
// stage to draw, so it is here to write the colour of a target there is none of
void main() {
    out_color = vec4(1.0);
}
