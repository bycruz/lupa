--- Fixed sizes and starting capacities lupa allocates up front.
---@class lupa.draw.Limits
---@field textures number layers in the shared texture array
---@field textureWidth number
---@field textureHeight number
---@field modelStack number depth of the model matrix stack
---@field instances number starting instance capacity of a frame
---@field draws number starting indirect draw capacity of a frame
---@field arenaVertices number starting mesh arena size in bytes
---@field arenaIndices number
---@field uvScaleFloats number floats per texture slot in the uv scale table
---@field uvScalesRevision number revision the uv scale table starts at

return {
	textures = 256,
	textureWidth = 512,
	textureHeight = 512,
	modelStack = 32,
	instances = 1024,
	draws = 256,
	arenaVertices = 4 * 1024 * 1024,
	arenaIndices = 1024 * 1024,
	uvScaleFloats = 4,
	uvScalesRevision = 1,
}
