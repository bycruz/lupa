#version 450

// Vertex stage for instanced mesh draws.
//
// The immediate path bakes the model transform into the vertices on the CPU,
// which is why the non-instanced mesh path never needs a matrix here. This path
// instead uploads a mesh's vertices once and applies a per-instance matrix in
// the shader, so drawing a mesh N times costs N instance records rather than N
// copies of every vertex.
//
// The fragment stage is shared with the immediate path, so the varyings here
// match main.vert.glsl exactly.

#ifndef VULKAN
out gl_PerVertex {
    vec4 gl_Position;
};
#define BINDING(x) layout(binding = x)
#else
#define BINDING(x) layout(set = 0, binding = x)
#endif

// Binding 0: the mesh's own vertices, 8 floats each (position, normal, uv).
layout(location = 0) in vec3 a_position;
layout(location = 1) in vec2 a_uv;
layout(location = 2) in vec3 a_normal;

// Binding 1: one element per instance, 112 bytes: the world matrix, colour,
// texture index and the sampled rectangle.
layout(location = 3) in vec4 a_model0;
layout(location = 4) in vec4 a_model1;
layout(location = 5) in vec4 a_model2;
layout(location = 6) in vec4 a_model3;
layout(location = 7) in vec4 a_color;
layout(location = 8) in float a_textureIndex;

// The sampled rectangle, in the same (u0, v0, spanU, spanV) form the immediate
// path bakes into vertices, so setTextureRect applies to instances too.
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
    mat4 model = mat4(a_model0, a_model1, a_model2, a_model3);

    vec4 worldPos = model * vec4(a_position, 1.0);
    v_worldPos = worldPos.xyz;
    v_uv = a_uvRect.xy + a_uv * a_uvRect.zw;
    v_normal = normalize(mat3(model) * a_normal);
    v_color = a_color;
    v_textureIndex = a_textureIndex;

    gl_Position = u_viewProj * worldPos;
}
