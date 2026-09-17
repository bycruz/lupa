local ffi = require("ffi")

-- safety: the transform block embeds LupaMat4, which lupa.math declares
require("lupa.math")

ffi.cdef [[
    /* safety: the world matrix's fourth row is always (0, 0, 0, 1) and the shader puts
       it back rather than reading it, which is why this leaves it out */
    typedef struct {
        float model0x, model0y, model0z;
        float model1x, model1y, model1z;
        float model2x, model2y, model2z;
        float model3x, model3y, model3z, model3w;
        uint8_t r, g, b, a;
        float textureIndex;
        float uvU0, uvV0, uvSpanU, uvSpanV;
        /* safety: a mesh's vertices are stored as 16 bit integers of its own size, so
           what one of them is worth travels with the instance that draws it */
        float positionScale;
        float uvScale;
    } LupaInstance;

    /* safety: matches VkDrawIndexedIndirectCommand and OpenGL's
       DrawElementsIndirectCommand, so the same records drive either backend */
    typedef struct {
        uint32_t indexCount;
        uint32_t instanceCount;
        uint32_t firstIndex;
        int32_t vertexOffset;
        uint32_t firstInstance;
    } LupaDrawRecord;

    typedef struct {
        LupaMat4 viewProj;
        LupaMat4 lightViewProj[4];
    } LupaTransforms;

    /* safety: a pass cannot be told which cascade it is by a uniform the whole frame
       shares, so each cascade gets a block of its own and the pass binds that one */
    typedef struct {
        LupaMat4 lightViewProj;
    } LupaShadowTransforms;

    /* safety: std140 pads every array element to a 16 byte boundary, so this is two
       vec4s and the shader declares the same shape */
    typedef struct {
        float color[3];
        float kind;
        float at[3];
        float radius;
    } LupaLight;

    /* safety: everything up to the lights is laid out in vec4s, because std140 starts
       an array of structs on a 16 byte boundary, and the shader declares the same shapes */
    typedef struct {
        float ambientColor[3];
        float lightCount;
        float cameraPos[3];
        float shadowLight;
        float shadowEnabled;
        float shadowCascades;
        float shadowBlend;
        float shadowBias;
        float shadowFilter;
        float shadowNormalBias;
        float shadowTexel;
        float texelInsetU;
        float fogColor[3];
        float fogFar;
        float cameraForward[3];
        float texelInsetV;
        /* safety: std140 starts the array of splits on a 16 byte boundary, so the shader
           reserves a vec3 of its own here and these fill the same gap both ways */
        float fogNear;
        float _pad0;
        float _pad1;
        float _pad2;
        float shadowSplits[4];
        float shadowTexels[4];
        LupaLight lights[8];
    } LupaLighting;
]]

---@class lupa.draw.Instance: ffi.cdata*
---@field model0x number
---@field model0y number
---@field model0z number
---@field model1x number
---@field model1y number
---@field model1z number
---@field model2x number
---@field model2y number
---@field model2z number
---@field model3x number
---@field model3y number
---@field model3z number
---@field model3w number
---@field r number
---@field g number
---@field b number
---@field a number
---@field textureIndex number
---@field uvU0 number
---@field uvV0 number
---@field uvSpanU number
---@field uvSpanV number
---@field positionScale number what one unit of a vertex position is worth
---@field uvScale number what one unit of a vertex uv is worth

---@class lupa.draw.DrawRecord: ffi.cdata*
---@field indexCount number
---@field instanceCount number
---@field firstIndex number
---@field vertexOffset number
---@field firstInstance number

---@class lupa.draw.Transforms: ffi.cdata*
---@field viewProj lupa.math.Mat4
---@field lightViewProj lupa.math.Mat4[] one per cascade, each a view of its own

---@class lupa.draw.ShadowTransforms: ffi.cdata*
---@field lightViewProj lupa.math.Mat4 the cascade the pass it is bound to draws

---@class lupa.draw.LightUniform: ffi.cdata*
---@field color number[]
---@field kind number 0 for a directional light, 1 for a point light
---@field at number[] the direction it travels in, or the position it sits at
---@field radius number how far a point light reaches

---@class lupa.draw.LightingUniform: ffi.cdata*
---@field ambientColor number[]
---@field lightCount number
---@field cameraPos number[]
---@field shadowLight number the index of the light that casts, or -1
---@field shadowEnabled number
---@field shadowCascades number how many cascades the map holds
---@field shadowBlend number share of a cascade's range blended into the next
---@field shadowBias number depth offset that keeps a surface from shadowing itself
---@field shadowFilter number width of the shadow filter, in shadow texels
---@field shadowNormalBias number shadow texels a sample is pushed along its normal
---@field shadowTexel number one over the shadow map's edge, in texels
---@field cameraForward number[] the direction the camera looks in
---@field fogColor number[] what the view fades into at its far end
---@field fogNear number how far away the fade begins
---@field fogFar number how far the fade is complete, 0 for no fade
---@field shadowSplits number[] how far each cascade reaches, in world units
---@field shadowTexels number[] how much of the world one texel of each covers
---@field lights lupa.draw.LightUniform[]
---@field texelInsetU number half a texel of a texture layer, in the layer's own uv
---@field texelInsetV number

---@class lupa.draw.Records
---@field instanceStride number bytes per instance record
---@field drawStride number bytes per draw command
---@field transformsSize number
---@field shadowTransformsSize number
---@field lightingSize number
---@field newInstances ffi.ctype* LupaInstance[?]
---@field newDraws ffi.ctype* LupaDrawRecord[?]
---@field newTransforms fun(): lupa.draw.Transforms
---@field newShadowTransforms fun(): lupa.draw.ShadowTransforms
---@field newLighting fun(): lupa.draw.LightingUniform

---@type fun(): lupa.draw.Transforms
---@diagnostic disable-next-line: assign-type-mismatch
local transformsType = ffi.typeof("LupaTransforms")

---@type fun(): lupa.draw.ShadowTransforms
---@diagnostic disable-next-line: assign-type-mismatch
local shadowTransformsType = ffi.typeof("LupaShadowTransforms")

---@type fun(): lupa.draw.LightingUniform
---@diagnostic disable-next-line: assign-type-mismatch
local lightingType = ffi.typeof("LupaLighting")

return {
	instanceStride = ffi.sizeof("LupaInstance"),
	drawStride = ffi.sizeof("LupaDrawRecord"),
	transformsSize = ffi.sizeof("LupaTransforms"),
	shadowTransformsSize = ffi.sizeof("LupaShadowTransforms"),
	lightingSize = ffi.sizeof("LupaLighting"),
	newInstances = ffi.typeof("LupaInstance[?]"),
	newDraws = ffi.typeof("LupaDrawRecord[?]"),
	newTransforms = transformsType,
	newShadowTransforms = shadowTransformsType,
	newLighting = lightingType,
}
