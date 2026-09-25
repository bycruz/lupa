local hood = require("hood")
local ffi = require("ffi")

local limits = require("lupa.draw.limits")
local records = require("lupa.draw.records")

local vertexShader = require("lupa.shaders.main.vert")
local fragmentShader = require("lupa.shaders.main.frag")
local shadowVertexShader = require("lupa.shaders.shadow.vert")
local shadowFragmentShader = require("lupa.shaders.shadow.frag")

-- safety: half a texel into the layer, or a wrapped sample reads the texel next to the
-- image, which belongs to the layer and holds nothing
local TEXEL_INSET_U = 0.5 / limits.textureWidth
local TEXEL_INSET_V = 0.5 / limits.textureHeight

local backend = os.getenv("BACKEND") or "vulkan"
local isVulkan = backend == "vulkan"
local shaderType = isVulkan and "spirv" or "glsl"

-- safety: one vec4 per texture slot, matching the shader's std140 uv scale array
local UV_SCALES_SIZE = limits.textures * limits.uvScaleFloats * 4

--- safety: Vulkan samples through a sampler of its own and OpenGL through the texture's
--- own unit, so the two backends do not agree on what the sampler binding is
local SAMPLER_BINDING = isVulkan and 3 or 2

local BINDING = {
	transforms = 0,
	lighting = 1,
	texture = 2,
	sampler = SAMPLER_BINDING,
	uvScales = 4,
	shadow = 5,
	shadowSampler = isVulkan and 6 or 5,
}

---@type fun(entries: table[]): table[]
local function sortByBinding(entries)
	table.sort(entries, function(a, b)
		return a.binding < b.binding
	end)
	return entries
end

---@type fun(device: hood.Device, buffer: hood.Buffer, size: number, data: ffi.cdata*, offset: number?)
local function upload(device, buffer, size, data, offset)
	offset = offset or 0
	if buffer.isMapped then
		ffi.copy(buffer:mappedPointer(offset), data, size)
		return
	end
	device.queue:writeBuffer(buffer, size, data, offset)
end

-- safety: hood's queue:writeBuffer drains the queue on every call, so writes go through
-- one encoder and are submitted together by `flush`
---@class lupa.draw.Uploads
---@field device hood.Device
---@field encoder hood.CommandEncoder?
local Uploads = {}
Uploads.__index = Uploads

---@type fun(device: hood.Device): lupa.draw.Uploads
local function newUploads(device)
	return setmetatable({ device = device, encoder = nil }, Uploads)
end

---@type fun(self: lupa.draw.Uploads, buffer: hood.Buffer, size: number, data: ffi.cdata*, offset: number?)
function Uploads:write(buffer, size, data, offset)
	if size == 0 then
		return
	end

	if buffer.isMapped then
		ffi.copy(buffer:mappedPointer(offset or 0), data, size)
		return
	end

	if not self.encoder then
		self.encoder = self.device:createCommandEncoder()
	end
	self.encoder:writeBuffer(buffer, size, data, offset)
end

function Uploads:flush()
	local encoder = self.encoder
	if not encoder then
		return
	end

	self.encoder = nil

	local command = encoder:finish()
	self.device.queue:submit(command)

	-- safety: the copies read staging memory the command buffer owns, so it can only
	-- be released once they have run
	self.device.queue:waitIdle()
	---@diagnostic disable-next-line: undefined-field -- hood.CommandBuffer is declared empty
	command:destroy()
end

---@type fun(device: hood.Device, cascades: number): hood.Buffer[]
local function createShadowTransforms(device, cascades)
	local buffers = {}
	for index = 1, cascades do
		buffers[index] = device:createBuffer({
			size = records.shadowTransformsSize,
			usages = { "UNIFORM", "COPY_DST" },
			mapped = true,
		})
	end
	return buffers
end

-- safety: one buffer set per frame in flight, because a shared set would write a frame's
-- geometry into memory a frame still in flight is reading
---@type fun(device: hood.Device, instanceCapacity: number, drawCapacity: number): lupa.draw.Slot
local function createSlot(device, instanceCapacity, drawCapacity)
	return {
		instanceBuffer = device:createBuffer({
			size = records.instanceStride * instanceCapacity,
			usages = { "VERTEX", "COPY_DST" },
			mapped = true,
		}),
		indirectBuffer = device:createBuffer({
			size = records.drawStride * drawCapacity,
			usages = { "INDIRECT", "COPY_DST" },
			mapped = true,
		}),
		transformsBuffer = device:createBuffer({
			size = records.transformsSize,
			usages = { "UNIFORM", "COPY_DST" },
			mapped = true,
		}),
		lightingBuffer = device:createBuffer({
			size = records.lightingSize,
			usages = { "UNIFORM", "COPY_DST" },
			mapped = true,
		}),
		overlayTransformsBuffer = device:createBuffer({
			size = records.transformsSize,
			usages = { "UNIFORM", "COPY_DST" },
			mapped = true,
		}),
		overlayLightingBuffer = device:createBuffer({
			size = records.lightingSize,
			usages = { "UNIFORM", "COPY_DST" },
			mapped = true,
		}),
		uvScalesBuffer = device:createBuffer({
			size = UV_SCALES_SIZE,
			usages = { "UNIFORM", "COPY_DST" },
			mapped = true,
		}),
		-- safety: a shadow pass cannot be told which cascade it is drawing by a
		-- uniform the whole frame shares, so each cascade has a block of its own
		shadowTransforms = createShadowTransforms(device, limits.shadowCascades),
		instanceCapacity = instanceCapacity,
		drawCapacity = drawCapacity,
		uvScalesRevision = limits.uvScalesRevision,
	}
end

---@type fun(device: hood.Device, width: number, height: number): hood.Texture, hood.TextureView
local function createDepth(device, width, height)
	-- safety: hood derives the render area from the swapchain texture, so a depth
	-- attachment of the window's size would be invalid
	local texture = device:createTexture({
		extents = { dim = "2d", width = width, height = height },
		format = "depth24plus",
		usages = { "RENDER_ATTACHMENT" },
	})

	return texture, texture:createView({})
end

---@type fun(device: hood.Device, width: number, height: number): lupa.draw.Capture
local function createCapture(device, width, height)
	local texture = device:createTexture({
		extents = { dim = "2d", width = width, height = height },
		format = "rgba8unorm",
		usages = { "RENDER_ATTACHMENT", "COPY_SRC" },
	})

	return {
		texture = texture,
		view = texture:createView({}),
		buffer = device:createBuffer({
			size = width * height * 4,
			usages = { "MAP_READ" },
		}),
	}
end

---@param device hood.Device
---@param layout hood.BindGroupLayout
---@param shadow lupa.draw.ShadowTargets
---@param textureView hood.TextureView
---@param sampler hood.Sampler
---@param buffers { transforms: hood.Buffer, lighting: hood.Buffer }
---@param slot lupa.draw.Slot
---@return hood.BindGroup
local function createBindGroup(device, layout, shadow, textureView, sampler, buffers, slot)
	return device:createBindGroup({
		layout = layout,
		entries = sortByBinding({
			{ binding = BINDING.transforms, type = "uniform-buffer", buffer = buffers.transforms },
			{ binding = BINDING.lighting, type = "uniform-buffer", buffer = buffers.lighting },
			{ binding = BINDING.texture, type = "texture", texture = textureView },
			{ binding = BINDING.uvScales, type = "uniform-buffer", buffer = slot.uvScalesBuffer },
			{ binding = BINDING.sampler, type = "sampler", sampler = sampler },
			{ binding = BINDING.shadow, type = "texture", texture = shadow.view },
			{ binding = BINDING.shadowSampler, type = "sampler", sampler = shadow.sampler },
		}),
	})
end

---@type fun(device: hood.Device, layout: hood.BindGroupLayout, buffer: hood.Buffer): hood.BindGroup
local function createShadowBindGroup(device, layout, buffer)
	return device:createBindGroup({
		layout = layout,
		entries = {
			{
				binding = BINDING.transforms,
				type = "uniform-buffer",
				visibility = { "VERTEX" },
				buffer = buffer,
			},
		},
	})
end

---@type fun(device: hood.Device, size: number, cascades: number): lupa.draw.ShadowTargets
local function createShadowTargets(device, size, cascades)
	-- safety: the map is a depth target the frame samples directly. Packing the depth
	-- into a colour target instead meant writing a colour target and a depth target and
	-- then reading the depth back out of four bytes, which is both more bytes per texel
	-- and four fetches per comparison
	local map = device:createTexture({
		extents = { dim = "2d", width = size, height = size, count = cascades },
		format = "depth32float",
		usages = { "RENDER_ATTACHMENT", "TEXTURE_BINDING" },
	})

	local layers = {}
	for index = 0, cascades - 1 do
		layers[index + 1] = map:createView({ baseArrayLayer = index, layerCount = 1 })
	end

	return {
		size = size,
		cascades = cascades,
		map = map,
		view = map:createView({}),
		layers = layers,
		-- safety: a depth map is compared by the sampler rather than read and compared
		-- by the shader, so it goes through a comparison sampler, and it is the linear
		-- filtering here that makes a tap cover four texels instead of one
		sampler = device:createSampler({
			minFilter = "linear",
			magFilter = "linear",
			mipmapFilter = "nearest",
			lodMaxClamp = 0,
			compareOp = "less-equal",
			addressModeU = "clamp-to-edge",
			addressModeV = "clamp-to-edge",
			addressModeW = "clamp-to-edge",
		}),
	}
end

-- safety: the maps clear to far, so a texel nothing was drawn into leaves what it covers
-- lit. There is no colour attachment at all: the depth the pass writes is the depth the
-- frame reads back, and a pass with no colour target still has to be told how to end
---@type fun(shadow: lupa.draw.ShadowTargets): hood.RenderPassDescriptor[]
local function createShadowRenderDescs(shadow)
	local descs = {}
	for index = 1, shadow.cascades do
		-- safety: no flag says the frame samples this afterwards. The map was made with
		-- TEXTURE_BINDING, and that is what makes a depth map one that is read back, the
		-- same way a texture's usages say what it is for everywhere else
		descs[index] = {
			colorAttachments = {},
			depthStencilAttachment = {
				op = { type = "clear", depth = 1 },
				texture = shadow.layers[index],
			},
		}
	end
	return descs
end

--- safety: hood's Vulkan swapchain carries these two, the OpenGL one neither, which is
--- why both are optional
---@class lupa.draw.Swapchain: hood.Swapchain
---@field imageCount number?
---@field format hood.TextureFormat?

---@class lupa.draw.Slot
---@field instanceBuffer hood.Buffer
---@field indirectBuffer hood.Buffer
---@field transformsBuffer hood.Buffer
---@field lightingBuffer hood.Buffer
---@field overlayTransformsBuffer hood.Buffer
---@field overlayLightingBuffer hood.Buffer
---@field uvScalesBuffer hood.Buffer
---@field shadowTransforms hood.Buffer[] one per cascade, holding that cascade's matrix
---@field instanceCapacity number
---@field drawCapacity number
---@field uvScalesRevision number
---@field bindGroup hood.BindGroup
---@field overlayBindGroup hood.BindGroup
---@field shadowBindGroups hood.BindGroup[] one per cascade, naming its own block

---@class lupa.draw.Gpu
---@field device hood.Device
---@field pipeline hood.Pipeline
---@field surface hood.Surface? nil when headless
---@field swapchain hood.Swapchain? nil when headless
---@field window winit.Window? nil when headless
---@field headless boolean
---@field targetWidth number
---@field targetHeight number
---@field frameCount number frames that can be in flight
---@field frames lupa.draw.Slot[] one buffer set per frame in flight
---@field bindGroupFor fun(slot: lupa.draw.Slot): hood.BindGroup
---@field overlayBindGroupFor fun(slot: lupa.draw.Slot): hood.BindGroup
---@field overlayPipeline hood.Pipeline
---@field shadowBindGroupFor fun(slot: lupa.draw.Slot, cascade: number): hood.BindGroup
---@field shadow lupa.draw.ShadowTargets
---@field shadowPipeline hood.Pipeline
---@field shadowRenderDescs hood.RenderPassDescriptor[] one per cascade, into its own layer
---@field texture hood.Texture the texture array, sampled by layer
---@field sampler hood.Sampler
---@field depthBuffer hood.Texture
---@field depthBufferView hood.TextureView
---@field uvScales ffi.cdata* one vec4 per texture layer
---@field uvScalesRevision number
---@field emptyViewDesc table
---@field renderDesc hood.RenderPassDescriptor
---@field maxTextureWidth number
---@field maxTextureHeight number

---@class lupa.draw.ShadowTargets
---@field size number edge of a map and of its depth target, in texels
---@field cascades number how many maps the array holds
---@field map hood.Texture the color target holding packed depth, one layer per cascade
---@field view hood.TextureView the whole array, as the frame samples it
---@field layers hood.TextureView[] one layer per cascade, as its pass renders it
---@field depth hood.Texture the targets the shadow passes test against
---@field depthLayers hood.TextureView[] one per cascade
---@field sampler hood.Sampler nearest and clamped, because the packed bytes do not filter

---@class lupa.draw.Capture
---@field texture hood.Texture
---@field view hood.TextureView
---@field buffer hood.Buffer

---@class lupa.draw.GpuKit
---@field new fun(window: winit.Window?, options: lupa.DrawOptions?): lupa.draw.Gpu
---@field upload fun(device: hood.Device, buffer: hood.Buffer, size: number, data: ffi.cdata*, offset: number?)
---@field createSlot fun(device: hood.Device, instanceCapacity: number, drawCapacity: number): lupa.draw.Slot
---@field newUploads fun(device: hood.Device): lupa.draw.Uploads
---@field createDepth fun(device: hood.Device, width: number, height: number): hood.Texture texture, hood.TextureView view
---@field createCapture fun(device: hood.Device, width: number, height: number): lupa.draw.Capture
---@field uvScalesSize number
local gpu = {}

---@type fun(window: winit.Window?, options: lupa.DrawOptions?): lupa.draw.Gpu
function gpu.new(window, options)
	options = options or {}
	local headless = options.headless or false

	local instance = hood.Instance.new({
		backend = backend,
		flags = headless and { "headless" } or {},
	})
	local adapter = instance:requestAdapter({ powerPreference = "high-performance" })
	local device = adapter:requestDevice()

	local surface, swapchain
	local surfaceConfig = { presentMode = "immediate" }
	local format = "rgba8unorm"
	local width, height = options.width or 800, options.height or 600
	local frameCount = 1

	if not headless then
		surface = instance:createSurface(assert(window, "lupa: createSurface needs a window"))
		swapchain = surface:configure(device, surfaceConfig)
		---@cast swapchain lupa.draw.Swapchain
		format = swapchain.format or "rgba8unorm"
		width, height = swapchain.width, swapchain.height
		frameCount = swapchain.imageCount or 1
	end

	-- safety: the OpenGL backend takes a location from the attribute's position
	-- across the bound layouts, so these stay in this order
	-- safety: a vertex position is 16 bits of the mesh's own size and a uv is 16 bits of
	-- its own range, and the two scales ride in the instance, so a mesh of any size keeps
	-- a precision of its extent over 32767
	local meshLayout = hood.VertexLayout.new({ stride = 16 })
		:withAttribute({ type = "i16", size = 3, offset = 0, location = 0 })
		:withAttribute({ type = "i8", size = 4, offset = 6, normalized = true, location = 2 })
		:withAttribute({ type = "i16", size = 2, offset = 10, location = 1 })

	local instanceLayout = hood.VertexLayout.new({ stride = records.instanceStride })
		:withAttribute({ type = "f32", size = 3, offset = 0, location = 3 })
		:withAttribute({ type = "f32", size = 3, offset = 12, location = 4 })
		:withAttribute({ type = "f32", size = 3, offset = 24, location = 5 })
		:withAttribute({ type = "f32", size = 4, offset = 36, location = 6 })
		:withAttribute({ type = "u8", size = 4, offset = 52, normalized = true, location = 7 })
		:withAttribute({ type = "f32", size = 1, offset = 56, location = 8 })
		:withAttribute({ type = "f32", size = 4, offset = 60, location = 9 })
		:withAttribute({ type = "f32", size = 1, offset = 76, location = 10 })
		:withAttribute({ type = "f32", size = 1, offset = 80, location = 11 })
		:withInstanceRate()

	local texture = device:createTexture({
		extents = {
			dim = "2d",
			width = limits.textureWidth,
			height = limits.textureHeight,
			count = limits.textures,
		},
		format = "rgba8unorm",
		usages = { "TEXTURE_BINDING", "COPY_DST" },
		mipLevelCount = limits.textureMips,
	})

	-- safety: a view covers one mip level unless it is told otherwise, so the array
	-- would be sampled at its largest level alone however many it holds
	local textureView = texture:createView({ levelCount = limits.textureMips })

	local sampler = device:createSampler({
		minFilter = "linear",
		magFilter = "linear",
		mipmapFilter = "linear",
		lodMaxClamp = limits.textureMips - 1,
		maxAnisotropy = limits.textureAnisotropy,
		-- safety: an image sits in the corner of a full-size layer, so repeating would
		-- blend its edges with the far side of the layer, and the tiled path wraps its
		-- own uv before it samples
		addressModeU = "clamp-to-edge",
		addressModeV = "clamp-to-edge",
		addressModeW = "clamp-to-edge",
	})

-- safety: a depth attachment cannot be sampled again in the same frame, so the map is a
-- color target with the depth packed into it, one layer per cascade
	local shadow = createShadowTargets(device, limits.shadowSize, limits.shadowCascades)
	local shadowLayout = device:createBindGroupLayout({
		{ binding = BINDING.transforms, type = "uniform-buffer", visibility = { "VERTEX" } },
	})

	local shadowPipeline = device:createPipeline({
		layout = shadowLayout,
		vertex = {
			module = { type = shaderType, source = shadowVertexShader },
			buffers = { meshLayout, instanceLayout },
		},
		fragment = {
			module = { type = shaderType, source = shadowFragmentShader },
			targets = {
				{ writeMask = hood.ColorWrites.All, format = "rgba8unorm" },
			},
		},
		depthStencil = {
			format = "depth24plus",
			depthWriteEnabled = true,
			depthCompare = "less-equal",
		},
	})

	local layoutEntries = {
		{ binding = BINDING.transforms, type = "uniform-buffer", visibility = { "FRAGMENT", "VERTEX" } },
		{ binding = BINDING.lighting, type = "uniform-buffer", visibility = { "FRAGMENT" } },
		{ binding = BINDING.texture, type = "texture", visibility = { "FRAGMENT" } },
		{ binding = BINDING.uvScales, type = "uniform-buffer", visibility = { "FRAGMENT" } },
		{ binding = BINDING.shadow, type = "texture", visibility = { "FRAGMENT" } },
	}
	if isVulkan then
		layoutEntries[#layoutEntries + 1] =
			{ binding = BINDING.sampler, type = "sampler", visibility = { "FRAGMENT" } }
	end
	layoutEntries[#layoutEntries + 1] =
		{ binding = BINDING.shadowSampler, type = "sampler", visibility = { "FRAGMENT" } }
	local bindGroupLayout = device:createBindGroupLayout(sortByBinding(layoutEntries))

-- safety: the overlay is drawn last, on top of the frame, so it ignores depth
	local overlayPipeline = device:createPipeline({
		layout = bindGroupLayout,
		vertex = {
			module = { type = shaderType, source = vertexShader },
			buffers = { meshLayout, instanceLayout },
		},
		fragment = {
			module = { type = shaderType, source = fragmentShader },
			targets = {
				{
					blend = "alpha-blending",
					format = format,
					writeMask = hood.ColorWrites.All,
				},
			},
		},
		depthStencil = {
			format = "depth24plus",
			depthWriteEnabled = false,
			depthCompare = "always",
		},
	})

	local pipeline = device:createPipeline({
		layout = bindGroupLayout,
		vertex = {
			module = { type = shaderType, source = vertexShader },
			buffers = { meshLayout, instanceLayout },
		},
		fragment = {
			module = { type = shaderType, source = fragmentShader },
			targets = {
				{
					blend = "alpha-blending",
					writeMask = hood.ColorWrites.All,
					format = format,
				},
			},
		},
		depthStencil = {
			format = "depth24plus",
			depthWriteEnabled = true,
			depthCompare = "less-equal",
		},
	})

---@type fun(slot: table): hood.BindGroup
	local function bindGroupFor(slot)
		return createBindGroup(device, bindGroupLayout, shadow, textureView, sampler,
			{ transforms = slot.transformsBuffer, lighting = slot.lightingBuffer }, slot)
	end

	local function overlayBindGroupFor(slot)
		return createBindGroup(device, bindGroupLayout, shadow, textureView, sampler,
			{ transforms = slot.overlayTransformsBuffer, lighting = slot.overlayLightingBuffer }, slot)
	end

	local function shadowBindGroupFor(slot, cascade)
		return createShadowBindGroup(device, shadowLayout, slot.shadowTransforms[cascade])
	end

	-- safety: the shader multiplies a quad's UV by its layer's scale, so an image in
	-- the corner of a layer still covers a quad whose UVs run 0..1
	local uvScales = ffi.new("float[?]", limits.textures * limits.uvScaleFloats)
	for i = 0, limits.textures * limits.uvScaleFloats - 1 do
		uvScales[i] = 1.0
	end

	local frames = {}
	for i = 1, frameCount do
		frames[i] = createSlot(device, limits.instances, limits.draws)
		upload(device, frames[i].uvScalesBuffer, UV_SCALES_SIZE, uvScales)
		frames[i].bindGroup = bindGroupFor(frames[i])
		frames[i].overlayBindGroup = overlayBindGroupFor(frames[i])
		frames[i].shadowBindGroups = {}
		for cascade = 1, limits.shadowCascades do
			frames[i].shadowBindGroups[cascade] = shadowBindGroupFor(frames[i], cascade)
		end
	end

	local depthBuffer, depthBufferView = createDepth(device, width, height)

	return {
		device = device,
		pipeline = pipeline,
		surface = surface,
		swapchain = swapchain,
		surfaceConfig = surfaceConfig,
		window = window,
		headless = headless,
		targetWidth = width,
		targetHeight = height,
		frameCount = frameCount,
		frames = frames,
		bindGroupFor = bindGroupFor,
		overlayBindGroupFor = overlayBindGroupFor,
		overlayPipeline = overlayPipeline,
		shadowBindGroupFor = shadowBindGroupFor,
		shadow = shadow,
		shadowPipeline = shadowPipeline,
		shadowRenderDescs = createShadowRenderDescs(shadow),
		texture = texture,
		sampler = sampler,
		depthBuffer = depthBuffer,
		depthBufferView = depthBufferView,
		uvScales = uvScales,
		uvScalesRevision = limits.uvScalesRevision,
		emptyViewDesc = {},
		renderDesc = {
			colorAttachments = {
				{
					op = { type = "clear", color = { r = 0.1, g = 0.1, b = 0.1, a = 1.0 } },
					texture = false, -- safety: replaced each frame by recordFrame
				},
			},
			depthStencilAttachment = {
				op = { type = "clear", depth = 1 },
				texture = depthBufferView,
			},
		},
		maxTextureWidth = limits.textureWidth,
		maxTextureHeight = limits.textureHeight,
	}
end

gpu.upload = upload
gpu.TEXEL_INSET_U = TEXEL_INSET_U
gpu.TEXEL_INSET_V = TEXEL_INSET_V
gpu.createSlot = createSlot
gpu.newUploads = newUploads
gpu.createDepth = createDepth
gpu.createCapture = createCapture
gpu.uvScalesSize = UV_SCALES_SIZE

return gpu
