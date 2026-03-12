#version 450

layout(location = 0) in vec3 a_position;
layout(location = 1) in vec2 a_uv;
layout(location = 2) in vec3 a_normal;
layout(location = 3) in vec4 a_color;
layout(location = 4) in float a_textureIndex;

layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec3 v_normal;
layout(location = 2) out vec4 v_color;
layout(location = 3) out vec3 v_worldPos;
layout(location = 4) out float v_textureIndex;

layout(set = 0, binding = 0) uniform Transforms {
    mat4 u_viewProj;
    mat4 u_model;
};

void main() {
    vec4 worldPos = u_model * vec4(a_position, 1.0);
    v_worldPos = worldPos.xyz;
    v_uv = a_uv;
    v_normal = normalize(mat3(u_model) * a_normal);
    v_color = a_color;
    v_textureIndex = a_textureIndex;
    gl_Position = u_viewProj * worldPos;
}
