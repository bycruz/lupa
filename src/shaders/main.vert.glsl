#version 450

// safety: Vulkan binds through descriptor set 0, OpenGL through a bare binding
#ifndef VULKAN
out gl_PerVertex {
    vec4 gl_Position;
};
#define BINDING(x) layout(binding = x)
#else
#define BINDING(x) layout(set = 0, binding = x)
#endif

// A mesh vertex: position, uv, and the normal as normalized bytes.
layout(location = 0) in vec3 a_position;
layout(location = 1) in vec2 a_uv;
layout(location = 2) in vec4 a_normal;

// One instance: the world matrix, its color, its texture layer and the sampled
// rectangle. safety: the matrix is affine, so its fourth row is (0, 0, 0, 1) and
// is put back here rather than uploaded as four zeroes per instance.
layout(location = 3) in vec3 a_model0;
layout(location = 4) in vec3 a_model1;
layout(location = 5) in vec3 a_model2;
layout(location = 6) in vec4 a_model3;
layout(location = 7) in vec4 a_color;
layout(location = 8) in float a_textureIndex;
layout(location = 9) in vec4 a_uvRect;

layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec3 v_normal;
layout(location = 2) out vec4 v_color;
layout(location = 3) out vec3 v_worldPos;
layout(location = 4) out float v_textureIndex;

BINDING(0) uniform Transforms {
    mat4 u_viewProj;
};

void main() {
    mat4 model = mat4(
        vec4(a_model0, 0.0),
        vec4(a_model1, 0.0),
        vec4(a_model2, 0.0),
        a_model3);

    vec4 worldPos = model * vec4(a_position, 1.0);
    v_worldPos = worldPos.xyz;
    v_uv = a_uvRect.xy + a_uv * a_uvRect.zw;
    v_normal = normalize(mat3(model) * a_normal.xyz);
    v_color = a_color;
    v_textureIndex = a_textureIndex;

    gl_Position = u_viewProj * worldPos;
}
