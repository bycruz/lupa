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

// A mesh vertex: position and uv are integers of the mesh's own size, and the normal
// is normalized bytes with the tile it samples in the fourth.
// safety: the two scales come from the instance, since one vertex range is drawn by
// instances of the same mesh and only the mesh knows how big it is
layout(location = 0) in ivec3 a_position;
layout(location = 1) in ivec2 a_uv;
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
layout(location = 10) in float a_positionScale;
layout(location = 11) in float a_uvScale;

layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec3 v_normal;
layout(location = 2) out vec4 v_color;
layout(location = 3) out vec3 v_worldPos;
layout(location = 4) out float v_textureIndex;
layout(location = 5) out float v_tile;

BINDING(0) uniform Transforms {
    mat4 u_viewProj;
    mat4 u_lightViewProj;
};

void main() {
    mat4 model = mat4(
        vec4(a_model0, 0.0),
        vec4(a_model1, 0.0),
        vec4(a_model2, 0.0),
        a_model3);

    vec3 position = vec3(a_position) * a_positionScale;
    vec2 uv = vec2(a_uv) * a_uvScale;
    vec4 worldPos = model * vec4(position, 1.0);
    v_worldPos = worldPos.xyz;

    // safety: a vertex that names its own tile carries a uv in tiles rather than in
    // the sampled rectangle, so the rectangle is only applied without one
    v_tile = a_normal.w;
    v_uv = v_tile < 0.0 ? (a_uvRect.xy + uv * a_uvRect.zw) : uv;
    v_normal = normalize(mat3(model) * a_normal.xyz);
    v_color = a_color;
    v_textureIndex = a_textureIndex;

    gl_Position = u_viewProj * worldPos;
}
