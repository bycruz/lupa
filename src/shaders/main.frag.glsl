#version 450

#ifndef VULKAN
#define BINDING(x) layout(binding = x)
#define TEXTURE2D_ARRAY sampler2DArray
#define SAMPLE_TEXTURE(tex, coord) texture(tex, coord)
#define SAMPLE_TEXTURE_GRAD(tex, coord, ddx, ddy) textureGrad(tex, coord, ddx, ddy)
#define SAMPLE_SHADOW(tex, coord) texture(tex, coord)
#else
#define BINDING(x) layout(set = 0, binding = x)
#define TEXTURE2D_ARRAY texture2DArray
#define SAMPLE_TEXTURE(tex, sampler, coord) texture(sampler2DArray(tex, sampler), coord)
#define SAMPLE_TEXTURE_GRAD(tex, sampler, coord, ddx, ddy) textureGrad(sampler2DArray(tex, sampler), coord, ddx, ddy)
#define SAMPLE_SHADOW(tex, sampler, coord) texture(sampler2DArray(tex, sampler), coord)
#endif

layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec3 v_normal;
layout(location = 2) in vec4 v_color;
layout(location = 3) in vec3 v_worldPos;
layout(location = 4) in float v_textureIndex;
layout(location = 5) in float v_tile;

layout(location = 0) out vec4 out_color;

// safety: the count here is the one records.lua sizes the array with, and the two are
// declared independently, so a change to either has to be made in both
#define CASCADE_COUNT 4

BINDING(0) uniform Transforms {
    mat4 u_viewProj;
    mat4 u_lightViewProj[CASCADE_COUNT];
};

// safety: the count here is the one records.lua sizes the array with, and the two are
// declared independently, so a change to either has to be made in both
#define LIGHT_COUNT 8

// One light: kind 0 travels along `at`, kind 1 sits there and reaches `radius`.
struct Light {
    vec3 color;
    float kind;
    vec3 at;
    float radius;
};

BINDING(1) uniform Lighting {
    vec3 u_ambientColor;
    float u_lightCount;
    vec3 u_cameraPos;
    float u_shadowLight;
    float u_shadowEnabled;
    float u_shadowCascades;
    float u_shadowBlend;
    float u_shadowBias;
    float u_shadowFilter;
    float u_shadowNormalBias;
    float u_shadowTexel;
    float u_texelInsetU;
    // safety: std140 would make room for a vec3 of its own before this one, and
    // records.lua leaves the same gap, so the splits land on the same slot in both
    vec3 u_fogColor;
    float u_fogFar;
    vec3 u_cameraForward;
    float u_texelInsetV;
    float u_fogNear;
    float _pad0;
    float _pad1;
    vec4 u_shadowSplits;
    vec4 u_shadowTexels;
    Light u_lights[LIGHT_COUNT];
};

// safety: a texture is sampled through a separate sampler object on Vulkan and
// through the texture's own unit on OpenGL
#ifndef VULKAN
BINDING(2) uniform TEXTURE2D_ARRAY u_textures;
#else
BINDING(2) uniform texture2DArray u_textures;
BINDING(3) uniform sampler u_sampler;
#endif

// safety: declared as vec4 because std140 strides a uniform array by 16 bytes
// whatever its element type, so the CPU writes the same spacing, and only .xy is used
BINDING(4) uniform TextureScales {
    vec4 u_uvScales[256];
};

// safety: a depth attachment cannot be sampled in the same frame, so a shadow map is
// a color target holding the fragment depth packed into its channels, and one layer of
// the array per cascade
#ifndef VULKAN
BINDING(5) uniform sampler2DArray u_shadow;
#else
BINDING(5) uniform texture2DArray u_shadow;
BINDING(6) uniform sampler u_shadowSampler;
#endif

float unpackDepth(vec4 rgba) {
    return dot(rgba, vec4(1.0, 1.0 / 255.0, 1.0 / 65025.0, 1.0 / 16581375.0));
}

// One texel of one cascade's map. A cascade is a layer of the array rather than a
// texture of its own, so a frame samples all of them through one binding.
float sampleShadowMap(vec2 uv, int cascade) {
#ifdef VULKAN
    return unpackDepth(SAMPLE_SHADOW(u_shadow, u_shadowSampler, vec3(uv, float(cascade))));
#else
    return unpackDepth(SAMPLE_SHADOW(u_shadow, vec3(uv, float(cascade))));
#endif
}

// How far one cascade reaches, in world units, and how much of the world one of its
// texels covers.
float cascadeFar(int cascade) {
    return cascade == 0 ? u_shadowSplits.x
        : cascade == 1 ? u_shadowSplits.y
        : cascade == 2 ? u_shadowSplits.z
        : u_shadowSplits.w;
}

float cascadeTexel(int cascade) {
    return cascade == 0 ? u_shadowTexels.x
        : cascade == 1 ? u_shadowTexels.y
        : cascade == 2 ? u_shadowTexels.z
        : u_shadowTexels.w;
}

// One comparison against the map of one cascade: is this piece of the world closer to
// the light than what the map holds for it.
float sampleCascade(int cascade, float texel, vec3 worldPos, vec3 normal, vec2 offset) {
    // safety: a surface is sampled where it stands pushed out along its own normal by
    // a texel or two. Up close a texel of the map covers several units of the world, so
    // the map's idea of where the surface is lands either side of it, and without the
    // push every surface would shadow itself in stripes
    vec3 at = worldPos + normal * (u_shadowNormalBias * texel);

    vec4 lightPos = u_lightViewProj[cascade] * vec4(at, 1.0);
    vec3 proj = lightPos.xyz / lightPos.w;
    proj.xy = proj.xy * 0.5 + 0.5;
    // safety: the map holds gl_FragCoord.z, which Vulkan already reports in [0, 1]
    // while OpenGL remaps its [-1, 1] clip depth into the depth range, and hood's
    // Vulkan viewport flip also turns the map's rows the other way up
#ifdef VULKAN
    proj.y = 1.0 - proj.y;
#else
    proj.z = proj.z * 0.5 + 0.5;
#endif
    if (proj.x < 0.0 || proj.x > 1.0 || proj.y < 0.0 || proj.y > 1.0 || proj.z > 1.0) {
        return 1.0;
    }

    float closest = sampleShadowMap(proj.xy + offset, cascade);
    return proj.z - u_shadowBias > closest ? 0.0 : 1.0;
}

// Nine taps in a square around the sample, weighted so the middle counts for most of
// it. What the filter buys is the few texels of fade that turn the staircase of a hard
// edge into a line; the width of it is what a game sets to choose how soft that is.
float filterCascade(int cascade, float texel, vec3 worldPos, vec3 normal, float width) {
    float lit = 0.0;

    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 offset = vec2(float(x), float(y)) * u_shadowTexel * width;
            float weight = (x == 0 ? 2.0 : 1.0) * (y == 0 ? 2.0 : 1.0);
            lit += weight * sampleCascade(cascade, texel, worldPos, normal, offset);
        }
    }

    return lit * (1.0 / 16.0);
}

// Which cascade covers this piece of the world, and how much of it is handed to the
// next one. Far enough into a cascade, the last share of its range is mixed into the
// one after it, so the join between two maps of different sharpness is not a line.
float shadowFactor(vec3 worldPos, vec3 normal) {
    if (u_shadowCascades < 0.5) {
        return 1.0;
    }

    float depth = dot(worldPos - u_cameraPos, u_cameraForward);
    int cascade = 0;
    while (float(cascade + 1) < u_shadowCascades && depth > cascadeFar(cascade)) {
        cascade++;
    }

    // past the last cascade, or past its far plane, nothing is shadowed
    if (depth > cascadeFar(cascade)) {
        return 1.0;
    }

    float texel = cascadeTexel(cascade);
    float lit = filterCascade(cascade, texel, worldPos, normal, u_shadowFilter);

    float far = cascadeFar(cascade);
    float near = cascade == 0 ? 0.0 : cascadeFar(cascade - 1);
    float fade = (far - near) * u_shadowBlend;
    if (fade > 0.0 && depth > far - fade && float(cascade) < u_shadowCascades - 1.5) {
        float blend = (depth - (far - fade)) / fade;
        float next = filterCascade(cascade + 1, cascadeTexel(cascade + 1), worldPos, normal, u_shadowFilter);
        lit = mix(lit, next, blend);
    }

    return lit;
}

// The tile a vertex names: 255 is read back as -1 and means the draw's own texture,
// anything else is layer * 3 + row into the texture array.
float namedTile() {
    return v_tile < -0.5 ? -1.0 : floor(v_tile * 127.0 + 0.5);
}

void main() {
    vec4 texColor;

    // safety: the span of the image, its emission and whether it is cut out all live in
    // one slot per texture, so whichever this fragment samples is read once here
    vec4 scales;
    float tile = namedTile();

    if (tile >= 0.0) {
        // safety: the uv of a merged face counts tiles across it, so it is wrapped
        // within one tile here, where the hardware can interpolate it first. Every
        // sample is then kept half a texel inside the image: on the wrap, a sample on
        // the edge would read the texel next to the image, which belongs to the layer
        // and is transparent, and a face with two blocks in it would show a see-through
        // seam down the join.
        float layer = floor(tile / 3.0);
        float row = tile - layer * 3.0;
        scales = u_uvScales[int(layer)];
        float insetU = u_texelInsetU;
        float insetV = u_texelInsetV;
        float rowSpan = scales.y / 3.0;
        vec2 span = vec2(scales.x - 2.0 * insetU, rowSpan - 2.0 * insetV);

        // safety: the level of detail comes from the uv before it is wrapped, because
        // the derivative of fract() jumps a whole tile at every tile boundary, and the
        // sample on the seam would come from the smallest level the sampler holds
        vec2 uvDx = vec2(dFdx(v_uv.x) * span.x, dFdx(v_uv.y) * span.y);
        vec2 uvDy = vec2(dFdy(v_uv.x) * span.x, dFdy(v_uv.y) * span.y);

        // safety: half a texel of inset only holds a sample inside its tile while the
        // level it comes from is filtered over no more than that, and a smaller level is
        // filtered over a whole footprint. Without holding the sample that same
        // footprint inside, a sample on the join of two blocks reads the empty layer
        // beside the image, or the tile of the face stacked above it, which is a seam
        // between every pair of blocks in the world
        vec2 base = vec2(fract(v_uv.x) * span.x + insetU, row * rowSpan + fract(v_uv.y) * span.y + insetV);
        vec2 reach = min(max(vec2(max(abs(uvDx.x), abs(uvDy.x)), max(abs(uvDx.y), abs(uvDy.y))),
            vec2(insetU, insetV)), span * 0.5);
        vec2 uv = clamp(base, vec2(reach.x, row * rowSpan + reach.y),
            vec2(scales.x - reach.x, row * rowSpan + rowSpan - reach.y));
#ifndef VULKAN
        texColor = SAMPLE_TEXTURE_GRAD(u_textures, vec3(uv, layer), uvDx, uvDy) * v_color;
#else
        texColor = SAMPLE_TEXTURE_GRAD(u_textures, u_sampler, vec3(uv, layer), uvDx, uvDy) * v_color;
#endif
    } else if (v_textureIndex < 0.0) {
        scales = vec4(1.0, 1.0, 0.0, 0.0);
        texColor = v_color;
    } else {
        scales = u_uvScales[int(v_textureIndex)];

        // safety: the image is in the corner of a full-size layer, so a sample within a
        // footprint of its edge reads whatever the layer holds beside it. The footprint
        // is a texel at the size an image is drawn at, and a whole block of them at the
        // smaller levels a small image is sampled from
        vec2 scaled = v_uv * scales.xy;
        vec2 reach = max(vec2(max(abs(dFdx(scaled.x)), abs(dFdy(scaled.x))),
            max(abs(dFdx(scaled.y)), abs(dFdy(scaled.y)))), vec2(u_texelInsetU, u_texelInsetV));
        vec2 uv = clamp(scaled, reach, max(scales.xy - reach, reach));
#ifndef VULKAN
        texColor = SAMPLE_TEXTURE(u_textures, vec3(uv, v_textureIndex)) * v_color;
#else
        texColor = SAMPLE_TEXTURE(u_textures, u_sampler, vec3(uv, v_textureIndex)) * v_color;
#endif
    }

    // safety: a texture with an alpha of under a half is not drawn at all where it is
    // clear, which is what leaves are: drawn with the opaque geometry, with their gaps
    // cut out of them rather than blended over whatever stands behind
    float cutout = scales.w;
    if (cutout > 0.5 && texColor.a < 0.5) {
        discard;
    }

    // safety: ambient is the floor the world is lit by, and it is what is left when a
    // frame carries no lights at all, so shaders are one code path rather than two
    vec3 lit = u_ambientColor * texColor.rgb + scales.z * texColor.rgb;

    // safety: the last of the view is faded into the sky, so the world ends at a
    // distance rather than at the edge of a chunk that is simply missing
    if (u_fogFar > u_fogNear) {
        float faded = clamp((distance(v_worldPos, u_cameraPos) - u_fogNear) / (u_fogFar - u_fogNear), 0.0, 1.0);
        lit = mix(lit, u_fogColor, faded * faded);
    }

    if (u_lightCount > 0.0) {
        vec3 normal = normalize(v_normal);
        float shadow = u_shadowEnabled > 0.5 ? shadowFactor(v_worldPos, normal) : 1.0;

        for (int index = 0; index < LIGHT_COUNT; index++) {
            if (float(index) >= u_lightCount) {
                break;
            }

            Light light = u_lights[index];
            vec3 towards;
            vec3 color = light.color;

            if (light.kind < 0.5) {
                towards = normalize(-light.at);
            } else {
                vec3 offset = light.at - v_worldPos;
                float distance = length(offset);
                towards = offset / max(distance, 0.0001);

                // safety: a point light falls off to nothing at its radius, squared so
                // the edge of its reach is soft rather than a visible ring
                float reach = clamp(1.0 - distance / max(light.radius, 0.0001), 0.0, 1.0);
                color *= reach * reach;
            }

            // safety: one map is rendered per frame, from the one light that asked for
            // it, so only that light's share of the frame is in shadow
            float litBy = abs(float(index) - u_shadowLight) < 0.5 ? shadow : 1.0;
            lit += color * max(dot(normal, towards), 0.0) * texColor.rgb * litBy;
        }
    }

    out_color = vec4(lit, texColor.a);
}
