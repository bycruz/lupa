local hood = require("hood")
local ffi = require("ffi")

local limits = require("lupa.draw.limits")
local records = require("lupa.draw.records")

local vertexShader = require("lupa.shaders.main.vert")
local fragmentShader = require("lupa.shaders.main.frag")

local backend = os.getenv("BACKEND") or "vulkan"
local isVulkan = backend == "vulkan"
local shaderType = isVulkan and "spirv" or "glsl"

--- One vec4 per texture slot, matching the shader's std140 uv scale array.
local UV_SCALES_SIZE = limits.textures * limits.uvScaleFloats * 4

--- safety: Vulkan samples through a sampler of its own, OpenGL through the unit
local SAMPLER_BINDING = isVulkan and 3 or 2

local BINDING = {
	transforms = 0,
	lighting = 1,
	texture = 2,
	sampler = SAMPLER_BINDING,
	uvScales = 4,
}

---@type fun(entries: table[]): table[]
local function sortByBinding(entries)
	table.sort(entries, function(a, b)
		return a.binding < b.binding
	end)
	return entries
end

--- Write CPU data into a buffer: a mapped buffer is written in place, anything
--- else through the queue.
---@type fun(device: hood.Device, buffer: hood.Buffer, size: number, data: ffi.cdata*, offset: number?)
local function upload(device, buffer, size, data, offset)
	offset = offset or 0
	if buffer.isMapped then
		ffi.copy(buffer:mappedPointer(offset), data, size)
		return
	end
	device.queue:writeBuffer(buffer, size, data, offset)
end

--- One set of the buffers a frame rewrites.
--- safety: per frame in flight, because sharing one set would write a frame's
--- geometry into memory a frame still in flight is reading
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
		uvScalesBuffer = device:createBuffer({
			size = UV_SCALES_SIZE,
			usages = { "UNIFORM", "COPY_DST" },
			mapped = true,
		}),
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
---@param textureView hood.TextureView
---@param sampler hood.Sampler
---@param slot table
---@return hood.BindGroup
local function createBindGroup(device, layout, textureView, sampler, slot)
	return device:createBindGroup({
		layout = layout,
		entries = sortByBinding({
			{ binding = BINDING.transforms, type = "uniform-buffer", buffer = slot.transformsBuffer },
			{ binding = BINDING.lighting, type = "uniform-buffer", buffer = slot.lightingBuffer },
			{ binding = BINDING.texture, type = "texture", texture = textureView },
			{ binding = BINDING.uvScales, type = "uniform-buffer", buffer = slot.uvScalesBuffer },
			{ binding = BINDING.sampler, type = "sampler", sampler = sampler },
		}),
	})
end

--- hood's Vulkan swapchain carries these two on top of the shared type; the
--- OpenGL one has neither, which is why imageCount is treated as optional.
---@class lupa.draw.Swapchain: hood.Swapchain
---@field imageCount number?
---@field format hood.TextureFormat?

--- One frame's buffers, with the bind group that names them.
---@class lupa.draw.Slot
---@field instanceBuffer hood.Buffer
---@field indirectBuffer hood.Buffer
---@field transformsBuffer hood.Buffer
---@field lightingBuffer hood.Buffer
---@field uvScalesBuffer hood.Buffer
---@field instanceCapacity number
---@field drawCapacity number
---@field uvScalesRevision number
---@field bindGroup hood.BindGroup

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

---@class lupa.draw.Capture
---@field texture hood.Texture
---@field view hood.TextureView
---@field buffer hood.Buffer

---@class lupa.draw.GpuKit
---@field new fun(window: winit.Window?, options: lupa.DrawOptions?): lupa.draw.Gpu
---@field upload fun(device: hood.Device, buffer: hood.Buffer, size: number, data: ffi.cdata*, offset: number?)
---@field createSlot fun(device: hood.Device, instanceCapacity: number, drawCapacity: number): lupa.draw.Slot
---@field createDepth fun(device: hood.Device, width: number, height: number): hood.Texture texture, hood.TextureView view
---@field createCapture fun(device: hood.Device, width: number, height: number): lupa.draw.Capture
---@field uvScalesSize number
local gpu = {}

--- The device and the pipeline, plus every buffer and target created from them.
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
	local meshLayout = hood.VertexLayout.new({ stride = 24 })
		:withAttribute({ type = "f32", size = 3, offset = 0, location = 0 })  -- position
		:withAttribute({ type = "f32", size = 2, offset = 16, location = 1 }) -- uv
		:withAttribute({ type = "i8", size = 4, offset = 12, normalized = true, location = 2 }) -- normal

	local instanceLayout = hood.VertexLayout.new({ stride = records.instanceStride })
		:withAttribute({ type = "f32", size = 3, offset = 0, location = 3 })  -- model column 0
		:withAttribute({ type = "f32", size = 3, offset = 12, location = 4 })
		:withAttribute({ type = "f32", size = 3, offset = 24, location = 5 })
		:withAttribute({ type = "f32", size = 4, offset = 36, location = 6 })  -- translation column
		:withAttribute({ type = "u8", size = 4, offset = 52, normalized = true, location = 7 }) -- color
		:withAttribute({ type = "f32", size = 1, offset = 56, location = 8 })  -- texture layer
		:withAttribute({ type = "f32", size = 4, offset = 60, location = 9 })  -- sampled rect
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
	})
	local textureView = texture:createView({})

	local sampler = device:createSampler({
		minFilter = "linear",
		magFilter = "linear",
		mipmapFilter = "linear",
		-- safety: the images have one mip level, so the sampler must not read others
		lodMaxClamp = 0,
		addressModeU = "repeat",
		addressModeV = "repeat",
		addressModeW = "repeat",
	})

	local layoutEntries = {
		{ binding = BINDING.transforms, type = "uniform-buffer", visibility = { "FRAGMENT", "VERTEX" } },
		{ binding = BINDING.lighting, type = "uniform-buffer", visibility = { "FRAGMENT" } },
		{ binding = BINDING.texture, type = "texture", visibility = { "FRAGMENT" } },
		{ binding = BINDING.uvScales, type = "uniform-buffer", visibility = { "FRAGMENT" } },
	}
	if isVulkan then
		layoutEntries[#layoutEntries + 1] =
			{ binding = BINDING.sampler, type = "sampler", visibility = { "FRAGMENT" } }
	end
	local bindGroupLayout = device:createBindGroupLayout(sortByBinding(layoutEntries))

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

	--- A bind group names concrete buffers, so every frame slot needs its own.
---@type fun(slot: table): hood.BindGroup
	local function bindGroupFor(slot)
		return createBindGroup(device, bindGroupLayout, textureView, sampler, slot)
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
					texture = false, -- replaced each frame
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
gpu.createSlot = createSlot
gpu.createDepth = createDepth
gpu.createCapture = createCapture
gpu.uvScalesSize = UV_SCALES_SIZE

return gpu
