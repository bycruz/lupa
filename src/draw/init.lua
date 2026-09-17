local ffi = require("ffi")

local batch = require("lupa.draw.batch")
local frame = require("lupa.draw.frame")
local gpu = require("lupa.draw.gpu")
local limits = require("lupa.draw.limits")
local meshes = require("lupa.draw.meshes")
local model = require("lupa.draw.model")
local records = require("lupa.draw.records")
local view = require("lupa.draw.view")

---@type ffi.ctype* uint8_t[?]
local byteArray = ffi.typeof("uint8_t[?]")

---@class lupa.TextureOptions
---@field emission number? 0 to 1 of a texture's own colour added to what lights it, so it reads as glowing
---@field cutout boolean? true to draw only the texels the texture gives an alpha of over a half
---@field rows number? how many tiles a texture of a block is stacked into, so its smaller
--- levels are filtered tile by tile rather than across the joins, defaults to 1

---@class lupa.DrawOptions
---@field headless boolean? draw without a window, onto an image that can be read back
---@field width number? size of the headless target, defaults to 800
---@field height number? size of the headless target, defaults to 600

---@class lupa.Draw: lupa.draw.Frame, lupa.draw.Model, lupa.draw.View
---@field headless boolean
---@field targetWidth number
---@field targetHeight number
---@field maxTextureWidth number
---@field maxTextureHeight number
---@field device hood.Device
---@field pipeline hood.Pipeline
---@field surface hood.Surface?
---@field swapchain hood.Swapchain?
---@field surfaceConfig hood.SurfaceConfig
---@field window winit.Window?
---@field frameCount number
---@field frames lupa.draw.Slot[]
---@field bindGroupFor fun(slot: lupa.draw.Slot): hood.BindGroup
---@field texture hood.Texture the texture array, sampled by layer
---@field sampler hood.Sampler
---@field depthBuffer hood.Texture
---@field depthBufferView hood.TextureView
---@field renderDesc hood.RenderPassDescriptor
---@field emptyViewDesc table
---@field uvScales ffi.cdata* one vec4 per texture layer
---@field uvScalesRevision number
---@field textureLayers number
---@field arena lupa.draw.Arena
---@field uploads lupa.draw.Uploads
---@field instances ffi.cdata* the frame's instance records
---@field instanceCapacity number
---@field instanceCount number instances in the frame being drawn
---@field drawRecords ffi.cdata* the frame's indirect draw commands
---@field drawRecordCapacity number
---@field drawRecordCount number indirect draw commands in the frame being drawn
---@field lastRecordMesh lupa.Mesh|false
---@field lastRecordTexture number
---@field modelStack lupa.math.Mat4[]
---@field modelDepth number
---@field model lupa.math.Mat4
---@field rotationScratch lupa.math.Mat4
---@field transforms lupa.draw.Transforms
---@field lighting lupa.draw.LightingUniform
---@field overlayTransforms lupa.draw.Transforms
---@field overlayLighting lupa.draw.LightingUniform
---@field overlayPipeline hood.Pipeline
---@field overlayBindGroupFor fun(slot: lupa.draw.Slot): hood.BindGroup
---@field sceneRecords number draw commands in the frame's scene, before the overlay
---@field overlayStart { instances: number, records: number }? set by beginOverlay
---@field shadowRecords number? records the shadow passes cover, set by endShadowCasters
---@field casterCounts number[]? how many of those records each cascade draws
---@field customView boolean
---@field camera lupa.draw.Camera?
---@field projWidth number?
---@field projHeight number?
---@field curR number
---@field curG number
---@field curB number
---@field curA number
---@field curTexture number
---@field texU0 number
---@field texV0 number
---@field texU1 number
---@field texV1 number
---@field shadowEnabled boolean
---@field shadowCascades number how many cascades the frame's shadows are split into
---@field shadowDistance number how far they reach, in world units
---@field shadowSplit number how much the splits favour the near view, 0 to 1
---@field shadowBlend number share of a cascade's range blended into the next
---@field shadowFilter number width of the shadow filter, in shadow texels
---@field shadowBias number
---@field shadowNormalBias number shadow texels a sample is pushed along its normal
---@field shadowCasterDepth number world units above a cascade that still cast into it
---@field shadowSplits number[] how far each cascade reaches, filled by setLighting
---@field shadow lupa.draw.ShadowTargets
---@field shadowPipeline hood.Pipeline
---@field shadowRenderDescs hood.RenderPassDescriptor[] one per cascade
---@field shadowBindGroupFor fun(slot: lupa.draw.Slot, cascade: number): hood.BindGroup
---@field capturing boolean
---@field capturePending boolean
---@field captureTexture hood.Texture|false
---@field captureView hood.TextureView|false
---@field captureBuffer hood.Buffer|false
---@field captureWidth number
---@field captureHeight number
local Draw = {}
Draw.__index = Draw

for _, part in ipairs({ frame, model, view }) do
	for name, fn in pairs(part.methods) do
		Draw[name] = fn
	end
end

---@type fun(window: winit.Window?, options: lupa.DrawOptions?): lupa.Draw
function Draw.new(window, options)
	local draw = setmetatable(gpu.new(window, options), Draw)
	---@cast draw lupa.Draw

	draw.arena = batch.newArena(draw.device)
	draw.uploads = gpu.newUploads(draw.device)
	draw.instances = records.newInstances(limits.instances)
	draw.instanceCapacity = limits.instances
	draw.instanceCount = 0
	draw.drawRecords = records.newDraws(limits.draws)
	draw.drawRecordCapacity = limits.draws
	draw.drawRecordCount = 0
	draw.lastRecordMesh = false
	draw.lastRecordTexture = -1

	draw.modelStack, draw.rotationScratch = model.newStack()
	draw.modelDepth = 1
	draw.model = draw.modelStack[1]

	local transforms, lighting = view.newState()
	---@cast transforms lupa.draw.Transforms
	---@cast lighting lupa.draw.LightingUniform
	draw.transforms, draw.lighting = transforms, lighting

	local overlayTransforms, overlayLighting = view.newState()
	---@cast overlayTransforms lupa.draw.Transforms
	---@cast overlayLighting lupa.draw.LightingUniform
	draw.overlayTransforms, draw.overlayLighting = overlayTransforms, overlayLighting
	draw.sceneRecords = 0
	draw.overlayStart = nil
	draw.shadowRecords = nil
	draw.customView = false
	draw.camera = nil
	draw.projWidth, draw.projHeight = nil, nil

	draw.curR, draw.curG, draw.curB, draw.curA = 1, 1, 1, 1
	draw.curTexture = -1
	draw.texU0, draw.texV0, draw.texU1, draw.texV1 = 0, 0, 1, 1
	draw.textureLayers = 0

	draw.shadowEnabled = false
	draw.shadowCascades = limits.shadowCascades
	draw.shadowDistance = limits.shadowDistance
	draw.shadowSplit = limits.shadowSplit
	draw.shadowBlend = limits.shadowBlend
	draw.shadowFilter = limits.shadowFilter
	draw.shadowBias = limits.shadowBias
	draw.shadowNormalBias = limits.shadowNormalBias
	draw.shadowCasterDepth = limits.shadowCasterDepth
	draw.casterCounts = nil

	-- safety: a game reads how far each cascade reaches while it draws, so the table
	-- is made once and filled in place rather than built per frame
	draw.shadowSplits = {}
	for index = 1, limits.shadowCascades do
		draw.shadowSplits[index] = 0
	end

	-- safety: a frame starts with no lights rather than whatever the last one left, and
	-- the same goes for the overlay's own lighting
	Draw.clearLighting(draw)

	draw.capturing = false
	draw.capturePending = false
	draw.captureTexture = false
	draw.captureView = false
	draw.captureBuffer = false
	draw.captureWidth = 0
	draw.captureHeight = 0

	return draw
end

---@type fun(self: lupa.Draw, r: number, g: number, b: number, a: number?)
function Draw:setColor(r, g, b, a)
	self.curR, self.curG, self.curB, self.curA = r, g, b, a or 1
end

---@type fun(self: lupa.Draw, x: number, y: number, w: number, h: number)
function Draw:rect(x, y, w, h)
	batch.emitRect(self, x, y, w, h)
end

---@type fun(self: lupa.Draw, x: number, y: number, z: number, size: number?)
function Draw:cube(x, y, z, size)
	local s = size or 1
	batch.emit(self, meshes.cube, x, y, z, s, s, s)
end

---@type fun(self: lupa.Draw, x: number, y: number, z: number, radius: number?, segments: number?)
function Draw:sphere(x, y, z, radius, segments)
	local mesh = meshes.sphere(segments or 24)
	local s = (radius or 1) * 2 -- safety: the unit sphere has radius 0.5
	batch.emit(self, mesh, x, y, z, s, s, s)
end

---@type fun(self: lupa.Draw, x: number, y: number, z: number, width: number?, depth: number?)
function Draw:plane(x, y, z, width, depth)
	batch.emit(self, meshes.plane, x, y, z, width or 1, 1, depth or 1)
end

---@type fun(self: lupa.Draw, mesh: lupa.Mesh, x: number?, y: number?, z: number?, sx: number?, sy: number?, sz: number?)
function Draw:mesh(mesh, x, y, z, sx, sy, sz)
	local s = sx or 1
	batch.emit(self, mesh, x or 0, y or 0, z or 0, s, sy or s, sz or s)
end

---@type fun(self: lupa.Draw, mesh: lupa.Mesh)
function Draw:releaseMesh(mesh)
	batch.releaseMesh(self, mesh)
end

-- safety: growing an arena re-uploads every mesh placed in it, so reserving what a world
-- needs before any of it is drawn turns a series of hitches into one allocation
---@type fun(self: lupa.Draw, vertexBytes: number, indexBytes: number)
function Draw:reserveMeshSpace(vertexBytes, indexBytes)
	batch.reserveSpace(self, vertexBytes, indexBytes)
end

---@type fun(self: lupa.Draw, texture: lupa.Texture|number|nil)
function Draw:setTexture(texture)
	if texture == nil then
		self.curTexture = -1
	elseif type(texture) == "number" then
		self.curTexture = texture
	else
		self.curTexture = texture.layer
	end

	self.texU0, self.texV0, self.texU1, self.texV1 = 0, 0, 1, 1
end

function Draw:clearTexture()
	self.curTexture = -1
	self.texU0, self.texV0, self.texU1, self.texV1 = 0, 0, 1, 1
end

---@type fun(self: lupa.Draw, u0: number, v0: number, u1: number, v1: number)
function Draw:setTextureRect(u0, v0, u1, v1)
	self.texU0, self.texV0, self.texU1, self.texV1 = u0, v0, u1, v1
end

---@type fun(self: lupa.Draw, r: number, g: number, b: number)
function Draw:setClearColor(r, g, b)
	local color = self.renderDesc.colorAttachments[1].op.color
	color.r, color.g, color.b = r, g, b
end

--- Half of a texel of the texture being added, box filtered into the level below it.
--- safety: the sample is clamped to the image, so a level that reaches past its edge
--- takes the edge texel rather than whatever the layer holds beside the image
--- Halve an image into the level below it.
---
--- safety: the rows of a tiled image are the tiles of one block, so a level is filtered
--- within the row it belongs to and never across the join between two tiles. Filtering
--- across it would make far away blocks average towards the colour of all their faces at
--- once, which reads as the world changing colour with distance
---@type fun(source: ffi.cdata*, width: number, height: number, rows: number, into: ffi.cdata*): number, number
local function halve(source, width, height, rows, into)
	local nextWidth, nextHeight = math.max(1, math.floor(width / 2)), math.max(1, math.floor(height / 2))
	local rowHeight = height / rows

	for y = 0, nextHeight - 1 do
		local row = math.min(math.floor(y * 2 / rowHeight), rows - 1)
		local last = math.min(math.floor((row + 1) * rowHeight) - 1, height - 1)
		local y0 = math.max(math.min(y * 2, last), math.floor(row * rowHeight))
		local y1 = math.max(math.min(y * 2 + 1, last), y0)

		for x = 0, nextWidth - 1 do
			local x0 = math.min(x * 2, width - 1)
			local x1 = math.min(x * 2 + 1, width - 1)
			local to = (y * nextWidth + x) * 4

			-- safety: a cdata array indexes from zero, so a texel's own offset is also the index of its
			-- first channel and offsetting by channel one past it would filter the texel to its right,
			-- which turns a level into the wrong channels entirely
			for channel = 0, 3 do
				local total = source[(y0 * width + x0) * 4 + channel]
					+ source[(y0 * width + x1) * 4 + channel]
					+ source[(y1 * width + x0) * 4 + channel]
					+ source[(y1 * width + x1) * 4 + channel]
				into[to + channel] = math.floor((total + 2) / 4)
			end
		end
	end

	return nextWidth, nextHeight
end

---@type fun(self: lupa.Draw, width: number, height: number, pixels: ffi.cdata*, options: lupa.TextureOptions?): number
function Draw:addTexture(width, height, pixels, options)
	local layer = self.textureLayers
	assert(layer < limits.textures, "lupa: texture array is full")
	if width > limits.textureWidth or height > limits.textureHeight then
		error(string.format("lupa: texture %dx%d exceeds the %dx%d layer size",
			width, height, limits.textureWidth, limits.textureHeight))
	end

	self.textureLayers = layer + 1
	self.device.queue:writeTexture(self.texture, {
		width = width,
		height = height,
		layer = layer,
		bytesPerRow = width * 4,
	}, pixels)

	-- safety: the levels below the largest one are built here rather than by a blit,
	-- because hood has no blit and because a level that covers a whole tile is what
	-- stops a texture from crawling when the ground is far away
	local levelWidth, levelHeight = width, height
	local source = pixels

	for mip = 1, limits.textureMips - 1 do
		if levelWidth < 2 or levelHeight < 2 then
			break
		end

		local next = byteArray(levelWidth * levelHeight * 4)
		local intoWidth, intoHeight = halve(source, levelWidth, levelHeight, options and options.rows or 1, next)

		self.device.queue:writeTexture(self.texture, {
			width = intoWidth,
			height = intoHeight,
			layer = layer,
			mip = mip,
			bytesPerRow = intoWidth * 4,
		}, next)

		source, levelWidth, levelHeight = next, intoWidth, intoHeight
	end

	-- safety: the image sits in the corner of a full-size layer, so a sample at UV 1
	-- would otherwise land outside it
	local slot = layer * limits.uvScaleFloats
	self.uvScales[slot] = width / limits.textureWidth
	self.uvScales[slot + 1] = height / limits.textureHeight
	self.uvScales[slot + 2] = options and options.emission or 0
	self.uvScales[slot + 3] = options and options.cutout and 1 or 0
	self.uvScalesRevision = self.uvScalesRevision + 1

	return layer
end

return Draw
