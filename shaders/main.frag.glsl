#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec3 v_normal;
layout(location = 2) in vec4 v_color;
layout(location = 3) in vec3 v_worldPos;
layout(location = 4) in float v_textureIndex;

layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 0) uniform Transforms {
    mat4 u_viewProj;
    mat4 u_model;
};

layout(set = 0, binding = 1) uniform Lighting {
    vec3 u_lightDir;
    float u_lightEnabled; // 0.0 = 2d, 1.0 = 3d
    vec3 u_lightColor;
    float _pad0;
    vec3 u_ambientColor;
    float _pad1;
    vec3 u_cameraPos;
    float _pad2;
};

layout(set = 0, binding = 2) uniform texture2DArray u_textures;
layout(set = 0, binding = 3) uniform sampler u_sampler;

layout(set = 0, binding = 4) uniform TextureScales {
    vec2 u_uvScales[256]; // or however many max textures you support
};

void main() {
    // vec4 texColor = texture(sampler2DArray(u_textures, u_sampler), vec3(v_uv * uvScale, v_textureIndex)) * v_color;
    vec4 texColor;
    if (v_textureIndex < 0.0) {
        texColor = v_color;
    } else {
        vec2 uvScale = u_uvScales[int(v_textureIndex)];
        texColor = texture(sampler2DArray(u_textures, u_sampler), vec3(v_uv * uvScale, v_textureIndex)) * v_color;
    }

    if (u_lightEnabled < 0.5) {
        out_color = texColor;
        return;
    }

    vec3 normal = normalize(v_normal);
    vec3 lightDir = normalize(-u_lightDir);
    vec3 viewDir = normalize(u_cameraPos - v_worldPos);
    vec3 halfDir = normalize(lightDir + viewDir);

    float diff = max(dot(normal, lightDir), 0.0);
    float spec = pow(max(dot(normal, halfDir), 0.0), 32.0);

    vec3 ambient = u_ambientColor * texColor.rgb;
    vec3 diffuse = u_lightColor * diff * texColor.rgb;
    vec3 specular = u_lightColor * spec * 0.3;

    out_color = vec4(ambient + diffuse + specular, texColor.a);
}
