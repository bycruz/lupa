local batch = require("lupa.draw.batch")
local frame = require("lupa.draw.frame")
local gpu = require("lupa.draw.gpu")
local limits = require("lupa.draw.limits")
local meshes = require("lupa.draw.meshes")
local model = require("lupa.draw.model")
local records = require("lupa.draw.records")
local view = require("lupa.draw.view")

---@class lupa.DrawOptions
---@field headless boolean? draw without a window, onto an image that can be read back
---@field width number? size of the headless target, defaults to 800
---@field height number? size of the headless target, defaults to 600

--- One frame's drawing state plus the resources behind it.
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
---@field lighting lupa.draw.Lighting
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
	---@cast lighting lupa.draw.Lighting
	draw.transforms, draw.lighting = transforms, lighting
	draw.customView = false
	draw.camera = nil
	draw.projWidth, draw.projHeight = nil, nil

	draw.curR, draw.curG, draw.curB, draw.curA = 1, 1, 1, 1
	draw.curTexture = -1
	draw.texU0, draw.texV0, draw.texU1, draw.texV1 = 0, 0, 1, 1
	draw.textureLayers = 0

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

--- Draw a rectangle: (x, y) is its bottom-left corner, in a view with y up.
---@type fun(self: lupa.Draw, x: number, y: number, w: number, h: number)
function Draw:rect(x, y, w, h)
	batch.emitRect(self, x, y, w, h)
end

--- Axis-aligned cube of edge `size` centred on (x, y, z).
---@type fun(self: lupa.Draw, x: number, y: number, z: number, size: number?)
function Draw:cube(x, y, z, size)
	local s = size or 1
	batch.emit(self, meshes.cube, x, y, z, s, s, s)
end

--- UV sphere of radius `radius` centred on (x, y, z).
---@type fun(self: lupa.Draw, x: number, y: number, z: number, radius: number?, segments: number?)
function Draw:sphere(x, y, z, radius, segments)
	local mesh = meshes.sphere(segments or 24)
	local s = (radius or 1) * 2 -- the unit sphere has radius 0.5
	batch.emit(self, mesh, x, y, z, s, s, s)
end

--- Horizontal plane spanning `width` on X and `depth` on Z, centred on (x, y, z).
---@type fun(self: lupa.Draw, x: number, y: number, z: number, width: number?, depth: number?)
function Draw:plane(x, y, z, width, depth)
	batch.emit(self, meshes.plane, x, y, z, width or 1, 1, depth or 1)
end

--- Draw a mesh from Assets:mesh or Assets:obj, through the model stack.
---@type fun(self: lupa.Draw, mesh: lupa.Mesh, x: number?, y: number?, z: number?, sx: number?, sy: number?, sz: number?)
function Draw:mesh(mesh, x, y, z, sx, sy, sz)
	local s = sx or 1
	batch.emit(self, mesh, x or 0, y or 0, z or 0, s, sy or s, sz or s)
end

--- Sample `texture` for everything drawn after this, or go back to untextured.
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

--- Stop sampling a texture: shapes go back to flat vertex color.
function Draw:clearTexture()
	self.curTexture = -1
	self.texU0, self.texV0, self.texU1, self.texV1 = 0, 0, 1, 1
end

--- Choose which part of the texture maps onto each shape, per draw call, with
--- (u0, v0) at the top-left of the source rectangle. Values past 1 repeat rather
--- than clamp, so tiling is a rectangle larger than the texture.
---@type fun(self: lupa.Draw, u0: number, v0: number, u1: number, v1: number)
function Draw:setTextureRect(u0, v0, u1, v1)
	self.texU0, self.texV0, self.texU1, self.texV1 = u0, v0, u1, v1
end

--- Upload RGBA8 pixels into the next free texture layer, and return its index.
---@type fun(self: lupa.Draw, width: number, height: number, pixels: ffi.cdata*): number
function Draw:addTexture(width, height, pixels)
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

	-- safety: the image sits in the corner of a full-size layer, so a sample at UV 1
	-- would otherwise land outside it
	local slot = layer * limits.uvScaleFloats
	self.uvScales[slot] = width / limits.textureWidth
	self.uvScales[slot + 1] = height / limits.textureHeight
	self.uvScalesRevision = self.uvScalesRevision + 1

	return layer
end

return Draw
