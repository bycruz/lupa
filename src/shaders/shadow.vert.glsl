#version 450

// The shadow pass: the same instances as the frame, seen from the light, with no
// color of its own. safety: Vulkan binds through descriptor set 0, OpenGL through
// a bare binding.
#ifndef VULKAN
out gl_PerVertex {
    vec4 gl_Position;
};
#define BINDING(x) layout(binding = x)
#else
#define BINDING(x) layout(set = 0, binding = x)
#endif

// safety: a mesh vertex position is an integer of the mesh's own size, and the scale
// that makes it a position comes from the instance that draws it
layout(location = 0) in ivec3 a_position;
layout(location = 1) in ivec2 a_uv;
layout(location = 2) in vec4 a_normal;

layout(location = 3) in vec3 a_model0;
layout(location = 4) in vec3 a_model1;
layout(location = 5) in vec3 a_model2;
layout(location = 6) in vec4 a_model3;
layout(location = 7) in vec4 a_color;
layout(location = 8) in float a_textureIndex;
layout(location = 9) in vec4 a_uvRect;
layout(location = 10) in float a_positionScale;

// safety: each cascade is drawn by a pass of its own, and a pass cannot be told which
// one it is by a block the whole frame shares, so it binds the cascade's own matrix
BINDING(0) uniform ShadowTransforms {
    mat4 u_lightViewProj;
};

void main() {
    mat4 model = mat4(
        vec4(a_model0, 0.0),
        vec4(a_model1, 0.0),
        vec4(a_model2, 0.0),
        a_model3);

    gl_Position = u_lightViewProj * model * vec4(vec3(a_position) * a_positionScale, 1.0);
}
