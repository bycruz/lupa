---@class lupa.draw.Limits
---@field textures number layers in the shared texture array
---@field textureWidth number
---@field textureHeight number
---@field textureMips number mip levels every texture in the array is given
---@field textureAnisotropy number samples taken along the longer axis of a stretched texel
---@field modelStack number depth of the model matrix stack
---@field instances number starting instance capacity of a frame
---@field draws number starting indirect draw capacity of a frame
---@field arenaVertices number starting mesh arena size in bytes
---@field arenaIndices number
---@field shadowSize number shadow map edge, in texels, per cascade
---@field shadowCascades number how many cascades a frame may split its shadows into
---@field shadowDistance number how far shadows reach, in world units
---@field shadowSplit number how much the default splits favour the near view, 0 to 1
---@field shadowBlend number share of a cascade's range blended into the next
---@field shadowFilter number width of the shadow filter, in shadow texels
---@field shadowBias number depth offset that keeps a surface from shadowing itself
---@field shadowNormalBias number shadow texels a sample is pushed along its normal
---@field shadowCasterDepth number world units above a cascade that still cast into it
---@field lights number how many lights a frame may carry
---@field uvScaleFloats number floats per texture slot in the uv scale table
---@field uvScalesRevision number revision the uv scale table starts at

return {
	textures = 256,
	textureWidth = 512,
	textureHeight = 512,
	textureMips = 4,
	textureAnisotropy = 4,
	modelStack = 32,
	instances = 1024,
	draws = 256,
	arenaVertices = 16 * 1024 * 1024,
	arenaIndices = 4 * 1024 * 1024,
	shadowSize = 1024,
	shadowCascades = 4,
	shadowDistance = 128,
	shadowSplit = 0.6,
	shadowBlend = 0.1,
	shadowFilter = 2,
	shadowBias = 0.0004,
	shadowNormalBias = 4,
	shadowCasterDepth = 64,
	lights = 8,
	uvScaleFloats = 4,
	uvScalesRevision = 1,
}
