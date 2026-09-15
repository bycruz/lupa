local ffi = require("ffi")

-- safety: the transform block embeds LupaMat4, which lupa.math declares
require("lupa.math")

ffi.cdef [[
    /* One instance of a mesh: the world matrix as its three linear columns plus the
       translation column, with the per-draw state that differs between instances.
       The fourth row is always (0, 0, 0, 1) and the shader puts it back rather than
       reading it, which saves four floats per instance. */
    typedef struct {
        float model0x, model0y, model0z;
        float model1x, model1y, model1z;
        float model2x, model2y, model2z;
        float model3x, model3y, model3z, model3w;
        uint8_t r, g, b, a;
        float textureIndex;
        float uvU0, uvV0, uvSpanU, uvSpanV;
    } LupaInstance;

    /* One indexed draw, read from a buffer instead of recorded into the command
       stream. Matches VkDrawIndexedIndirectCommand and OpenGL's
       DrawElementsIndirectCommand, so the same records drive either backend. */
    typedef struct {
        uint32_t indexCount;
        uint32_t instanceCount;
        uint32_t firstIndex;
        int32_t vertexOffset;
        uint32_t firstInstance;
    } LupaDrawRecord;

    /* Only the projection is a uniform: the world matrix travels per instance. */
    typedef struct {
        LupaMat4 viewProj;
    } LupaTransforms;

    typedef struct {
        float lightDir[3];
        float lightEnabled;
        float lightColor[3];
        float _pad0;
        float ambientColor[3];
        float _pad1;
        float cameraPos[3];
        float _pad2;
    } LupaLighting;
]]

--- One element of the instance array the vertex shader reads.
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

--- One element of the indirect draw buffer.
---@class lupa.draw.DrawRecord: ffi.cdata*
---@field indexCount number
---@field instanceCount number
---@field firstIndex number
---@field vertexOffset number
---@field firstInstance number

---@class lupa.draw.Transforms: ffi.cdata*
---@field viewProj lupa.math.Mat4

---@class lupa.draw.Lighting: ffi.cdata*
---@field lightDir number[]
---@field lightEnabled number
---@field lightColor number[]
---@field ambientColor number[]
---@field cameraPos number[]

--- The CPU-side layouts the shaders read, with their byte sizes.
---@class lupa.draw.Records
---@field instanceStride number bytes per instance record
---@field drawStride number bytes per draw command
---@field transformsSize number
---@field lightingSize number
---@field newInstances ffi.ctype* LupaInstance[?]
---@field newDraws ffi.ctype* LupaDrawRecord[?]
---@field newTransforms fun(): lupa.draw.Transforms
---@field newLighting fun(): lupa.draw.Lighting

---@type fun(): lupa.draw.Transforms
---@diagnostic disable-next-line: assign-type-mismatch
local transformsType = ffi.typeof("LupaTransforms")

---@type fun(): lupa.draw.Lighting
---@diagnostic disable-next-line: assign-type-mismatch
local lightingType = ffi.typeof("LupaLighting")

return {
	instanceStride = ffi.sizeof("LupaInstance"),
	drawStride = ffi.sizeof("LupaDrawRecord"),
	transformsSize = ffi.sizeof("LupaTransforms"),
	lightingSize = ffi.sizeof("LupaLighting"),
	newInstances = ffi.typeof("LupaInstance[?]"),
	newDraws = ffi.typeof("LupaDrawRecord[?]"),
	newTransforms = transformsType,
	newLighting = lightingType,
}
