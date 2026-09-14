local hood = require("hood")
local ffi = require("ffi")
local lpmath = require("lupa.math")

local vertexShader = require("lupa.shaders.main.vert")
local fragmentShader = require("lupa.shaders.main.frag")

---@class lupa.Draw
---@field private swapchain hood.Swapchain
---@field private pipeline hood.Pipeline
---@field private device hood.Device
---@field private surface hood.Surface
---@field private window winit.Window
---@field private vertexBuffer hood.Buffer
---@field private indexBuffer hood.Buffer
---@field private vertexCount number
---@field private indexCount number
---@field private depthBuffer hood.Texture
---@field private depthBufferView hood.TextureView
---@field private bindGroup hood.BindGroup
---@field private transformsBuffer hood.Buffer
---@field private lightingBuffer hood.Buffer
---@field private texture hood.Texture
---@field private sampler hood.Sampler
---@field private uvScalesBuffer hood.Buffer
---@field private vertices ffi.cdata*
---@field private indices ffi.cdata*
---@field private encoder hood.CommandEncoder?
---@field private curR number
---@field private curG number
---@field private curB number
---@field private curA number
---@field private curTexture number
---@field private transforms ffi.cdata*
---@field private lighting ffi.cdata*
---@field private identityModel lupa.math.Mat4
---@field private renderDesc table
---@field private emptyViewDesc table
local Draw = {}
Draw.__index = Draw

local MAX_TEXTURES = 256
local MAX_TEXTURE_WIDTH = 512
local MAX_TEXTURE_HEIGHT = 512

local MAX_VERTICES = 65536

--- Quads the vertex buffer can hold. The index buffer is built for this many
--- quads up front, so it never has to be rewritten.
local MAX_QUADS = MAX_VERTICES / 4

ffi.cdef [[
    typedef struct {
        float x, y, z;
        float u, v;
        float nx, ny, nz;
        float r, g, b, a;
        float textureIndex;
    } LupaVertex;

    typedef struct {
        LupaMat4 viewProj;
        LupaMat4 model;
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

---@class lupa.draw.ffi.Lighting: ffi.cdata*
---@field lightDir number[]
---@field lightEnabled number
---@field lightColor number[]
---@field ambientColor number[]
---@field cameraPos number[]

---@type fun(count: number): ffi.cdata*
local VertexArray = ffi.typeof("LupaVertex[?]")
local VertexArraySize = ffi.sizeof("LupaVertex")

---@type fun(count: number): ffi.cdata*
local IndexArray = ffi.typeof("uint16_t[?]")
local IndexArraySize = ffi.sizeof("uint16_t")

--- The index buffer for quad q is always vertices 4q, 4q+1, 4q+2, 4q+1, 4q+3,
--- 4q+2 -- two triangles in the same winding, with no dependency on anything but
--- the quad's position in the batch. That makes the whole buffer positional, so
--- it is generated once for MAX_QUADS quads and never rewritten: drawing the
--- first `indexCount` entries is correct for any number of quads.
---
--- This is why Draw:rect no longer writes indices and Draw:endFrame no longer
--- uploads them. It holds as long as rects are the only thing that emits
--- geometry, which is true of the public API (pushVertex/pushIndex are
--- private, and a future triangle path would need its own index strategy).
---@return ffi.cdata*
local function buildIndices()
	local indices = IndexArray(MAX_QUADS * 6)

	for q = 0, MAX_QUADS - 1 do
		local vc = q * 4
		local ic = q * 6
		indices[ic]     = vc
		indices[ic + 1] = vc + 1
		indices[ic + 2] = vc + 2
		indices[ic + 3] = vc + 1
		indices[ic + 4] = vc + 3
		indices[ic + 5] = vc + 2
	end

	return indices
end


---@type fun(proj: lupa.math.Mat4, model: lupa.math.Mat4): ffi.cdata*
local Transforms = ffi.typeof("LupaTransforms")
local TransformsSize = ffi.sizeof("LupaTransforms")

---@type fun(): lupa.draw.ffi.Lighting
local Lighting = ffi.typeof("LupaLighting")
local LightingSize = ffi.sizeof("LupaLighting")

local backend = os.getenv("BACKEND") or "vulkan"
local shaderType = backend == "vulkan" and "spirv" or "glsl"

---@param window winit.Window
function Draw.new(window)
	local instance = hood.Instance.new({ backend = backend, flags = {} })
	local adapter = instance:requestAdapter({ powerPreference = "high-performance" })
	local device = adapter:requestDevice()

	local surface = instance:createSurface(window)
	local surfaceConfig = { presentMode = "immediate" }
	local swapchain = surface:configure(device, surfaceConfig)

	local vertexLayout = hood.VertexLayout.new()
		:withAttribute({ type = "f32", size = 3, offset = 0 }) -- position
		:withAttribute({ type = "f32", size = 2, offset = 12 }) -- uv
		:withAttribute({ type = "f32", size = 3, offset = 20 }) -- normal
		:withAttribute({ type = "f32", size = 4, offset = 32 }) -- color
		:withAttribute({ type = "f32", size = 1, offset = 48 }) -- texture index

	local vertexBuffer = device:createBuffer({
		size = 1024 * 1024, -- 1MB for now, should be enough for simple shapes
		usages = { "VERTEX", "COPY_DST" }
	})

	local indexBuffer = device:createBuffer({
		size = 1024 * 1024, -- 1MB for now, should be enough for simple shapes
		usages = { "INDEX", "COPY_DST" }
	})

	local transformsBuffer = device:createBuffer({
		size = 64 * 1024, -- Enough for 1000 4x4 matrices
		usages = { "UNIFORM", "COPY_DST" }
	})

	local lightingBuffer = device:createBuffer({
		size = 64 * 1024, -- Enough for 1000 point lights (16 bytes each)
		usages = { "UNIFORM", "COPY_DST" }
	})

	local texture = device:createTexture({
		extents = { dim = "2d", width = MAX_TEXTURE_WIDTH, height = MAX_TEXTURE_HEIGHT, count = MAX_TEXTURES },
		format = "rgba8unorm",
		usages = { "TEXTURE_BINDING", "COPY_DST" }
	})

	local sampler = device:createSampler({
		minFilter = "linear",
		magFilter = "linear",
		mipmapFilter = "linear",
		addressModeU = "repeat",
		addressModeV = "repeat",
		addressModeW = "repeat"
	})

	local uvScalesBuffer = device:createBuffer({
		size = 64 * 1024, -- Enough for 1000 vec2 UV scales
		usages = { "UNIFORM", "COPY_DST" }
	})

	local isVulkan = backend == "vulkan"

	local bindings = {
		transforms = 0,
		lighting = 1,
		centralTexture = 2,
		centralSampler = isVulkan and 3 or 2, -- separate for Vulkan, same unit for OpenGL
		uvScales = 4
	}

	local textureView = texture:createView({})

	-- Build bind group layout
	local layoutEntries = {
		{ binding = bindings.transforms,     type = "uniform-buffer", visibility = { "FRAGMENT", "VERTEX" } },
		{ binding = bindings.lighting,       type = "uniform-buffer", visibility = { "FRAGMENT" } },
		{ binding = bindings.centralTexture, type = "texture",        visibility = { "FRAGMENT" } },
		{ binding = bindings.uvScales,       type = "uniform-buffer", visibility = { "FRAGMENT" } }
	}
	-- Only Vulkan needs a separate sampler entry in the layout
	if isVulkan then
		table.insert(layoutEntries, { binding = bindings.centralSampler, type = "sampler", visibility = { "FRAGMENT" } })
	end
	table.sort(layoutEntries, function(a, b) return a.binding < b.binding end)

	local bindGroupLayout = device:createBindGroupLayout(layoutEntries)

	-- Build bind group entries
	local bgEntries = {
		{ binding = bindings.transforms,     type = "uniform-buffer", buffer = transformsBuffer },
		{ binding = bindings.lighting,       type = "uniform-buffer", buffer = lightingBuffer },
		{ binding = bindings.centralTexture, type = "texture",        texture = textureView },
		{ binding = bindings.uvScales,       type = "uniform-buffer", buffer = uvScalesBuffer }
	}
	-- Sampler binds to same unit as texture in OpenGL, separate in Vulkan
	table.insert(bgEntries, { binding = bindings.centralSampler, type = "sampler", sampler = sampler })
	table.sort(bgEntries, function(a, b) return a.binding < b.binding end)

	bindGroup = device:createBindGroup({
		layout = bindGroupLayout,
		entries = bgEntries
	})

	local pipeline = device:createPipeline({
		layout = bindGroupLayout,
		vertex = {
			module = { type = shaderType, source = vertexShader },
			buffers = { vertexLayout }
		},
		fragment = {
			module = { type = shaderType, source = fragmentShader },
			targets = {
				{
					blend = "alpha-blending",
					writeMask = hood.ColorWrites.All,
					format = swapchain.format
				}
			}
		},
		-- primitive = {
		-- 	cullMode = "back",
		-- 	frontFace = "clockwise"
		-- },
		depthStencil = {
			format = "depth24plus",
			depthWriteEnabled = true,
			depthCompare = "less-equal"
		}
	})

	-- Match the swapchain extent rather than the window size: hood derives the
	-- render area from the swapchain texture, and a framebuffer whose depth
	-- attachment is smaller than that render area is invalid.
	local depthBuffer = device:createTexture({
		extents = { dim = "2d", width = swapchain.width, height = swapchain.height },
		format = "depth24plus",
		usages = { "RENDER_ATTACHMENT" }
	})

	local depthBufferView = depthBuffer:createView({})

	-- The index buffer is positional and never changes, so it is written once
	-- here instead of being re-uploaded every frame.
	device.queue:writeBuffer(indexBuffer, IndexArraySize * MAX_QUADS * 6, buildIndices())

	---@format disable-next
	return setmetatable({
		swapchain = swapchain,
		pipeline = pipeline,
		device = device,
		surface = surface,
		surfaceConfig = surfaceConfig,
		window = window,
		vertexBuffer = vertexBuffer,
		indexBuffer = indexBuffer,
		vertexCount = 0,
		indexCount = 0,
		depthBuffer = depthBuffer,
		depthBufferView = depthBufferView,
		bindGroup = bindGroup,
		transformsBuffer = transformsBuffer,
		lightingBuffer = lightingBuffer,
		texture = texture,
		sampler = sampler,
		uvScalesBuffer = uvScalesBuffer,
		vertices = VertexArray(MAX_VERTICES),
		curR = 1, curG = 1, curB = 1, curA = 1,
		curTexture = -1,
		transforms = Transforms(),
		lighting = Lighting(),
		identityModel = lpmath.mat4.identity(),
		emptyViewDesc = {},
		renderDesc = {
			colorAttachments = {
				{
					op = { type = "clear", color = { r = 0.1, g = 0.1, b = 0.1, a = 1.0 } },
					texture = false -- replaced each frame
				}
			},
			depthStencilAttachment = {
				op = { type = "clear", depth = 1 },
				texture = depthBufferView
			}
		}
	}, Draw)
end

---@param x number
---@param y number
---@param z number
---@param u number
---@param _v number
---@param nx number
---@param ny number
---@param nz number
---@param r number
---@param g number
---@param b number
---@param a number
---@param texIndex number?
---@private
function Draw:pushVertex(x, y, z, u, _v, nx, ny, nz, r, g, b, a, texIndex)
	local v = self.vertices[self.vertexCount]
	v.x, v.y, v.z = x, y, z
	v.u, v.v = u, _v
	v.nx, v.ny, v.nz = nx, ny, nz
	v.r, v.g, v.b, v.a = r, g, b, a
	v.textureIndex = texIndex or self.curTexture

	self.vertexCount = self.vertexCount + 1
end

--- Retained for symmetry with pushVertex. The index buffer is prebuilt and
--- positional (see buildIndices), so an arbitrary index value cannot be stored;
--- this only advances the draw count. Custom geometry built from pushVertex
--- would need its own index buffer.
---@param i number
---@private
function Draw:pushIndex(i)
	self.indexCount = self.indexCount + 1
end

---@param r number
---@param g number
---@param b number
---@param a number?
function Draw:setColor(r, g, b, a)
	self.curR = r; self.curG = g; self.curB = b; self.curA = a or 1.0
end

---@param x number
---@param y number
---@param w number
---@param h number
---@format disable-next
function Draw:rect(x, y, w, h)
	local verts = self.vertices
	local vc    = self.vertexCount
	local ic    = self.indexCount
	local r, g, b, a = self.curR, self.curG, self.curB, self.curA
	local tex   = self.curTexture

	local v = verts[vc]
	v.x, v.y, v.z = x, y, 0
	v.u, v.v = 0, 0
	v.nx, v.ny, v.nz = 0, 0, 1
	v.r, v.g, v.b, v.a = r, g, b, a
	v.textureIndex = tex

	v = verts[vc + 1]
	v.x, v.y, v.z = x + w, y, 0
	v.u, v.v = 1, 0
	v.nx, v.ny, v.nz = 0, 0, 1
	v.r, v.g, v.b, v.a = r, g, b, a
	v.textureIndex = tex

	v = verts[vc + 2]
	v.x, v.y, v.z = x, y + h, 0
	v.u, v.v = 0, 1
	v.nx, v.ny, v.nz = 0, 0, 1
	v.r, v.g, v.b, v.a = r, g, b, a
	v.textureIndex = tex

	v = verts[vc + 3]
	v.x, v.y, v.z = x + w, y + h, 0
	v.u, v.v = 1, 1
	v.nx, v.ny, v.nz = 0, 0, 1
	v.r, v.g, v.b, v.a = r, g, b, a
	v.textureIndex = tex

	-- The six indices for this quad are already in the index buffer: quad q
	-- always uses vertices 4q..4q+3 in the same order, so the pattern is
	-- positional and a prefix of it covers any quad count. See buildIndices().
	self.vertexCount = vc + 4
	self.indexCount  = ic + 6
end

function Draw:line()
end

---@private
function Draw:beginFrame()
	self.vertexCount = 0
	self.indexCount = 0
end

--- Rebuild everything that depends on the surface size. Called when the window
--- is resized, and from endFrame when the swapchain reports out-of-date.
---
--- The old swapchain is handed to hood so it can retire its sync objects and
--- command buffers; waitIdle inside that call makes it safe to drop the old
--- depth target afterwards.
---@private
function Draw:resize()
	local device = self.device
	local swapchain = self.surface:configure(device, self.surfaceConfig, self.swapchain)

	local oldDepth, oldDepthView = self.depthBuffer, self.depthBufferView
	local depthBuffer = device:createTexture({
		extents = { dim = "2d", width = swapchain.width, height = swapchain.height },
		format = "depth24plus",
		usages = { "RENDER_ATTACHMENT" }
	})
	local depthBufferView = depthBuffer:createView({})

	self.swapchain = swapchain
	self.depthBuffer = depthBuffer
	self.depthBufferView = depthBufferView
	self.renderDesc.depthStencilAttachment.texture = depthBufferView

	-- Force the projection to be rebuilt for the new size.
	self.projWidth, self.projHeight = nil, nil

	if oldDepthView then
		oldDepthView:destroy()
	end
	if oldDepth then
		oldDepth:destroy()
	end
end

---@private
function Draw:endFrame()
	-- The projection only depends on the window size, so it is rebuilt only
	-- when that changes rather than allocating a fresh matrix every frame.
	local width, height = self.window.width, self.window.height
	local transforms = self.transforms
	if self.projWidth ~= width or self.projHeight ~= height then
		self.projWidth, self.projHeight = width, height
		transforms.viewProj = lpmath.mat4.ortho(0, width, 0, height, -1, 1)
	end
	transforms.model = self.identityModel

	local lighting = self.lighting
	lighting.lightEnabled = 0.0

	local texture = self.swapchain:getCurrentTexture()
	if not texture then
		-- The swapchain no longer matches the surface (a resize happened).
		-- Rebuild it and skip this frame; the next one renders normally.
		self:resize()
		return
	end

	-- Ask the swapchain for the encoder, so hood reuses the command buffer it
	-- pre-allocated for this frame slot. Going through the device instead
	-- allocates a fresh command pool and command buffer every frame and never
	-- frees them.
	local encoder = self.swapchain:createCommandEncoder()
	encoder:writeBuffer(self.transformsBuffer, TransformsSize, transforms)
	encoder:writeBuffer(self.lightingBuffer, LightingSize, lighting)
	encoder:writeBuffer(self.vertexBuffer, VertexArraySize * self.vertexCount, self.vertices)
	-- The index buffer is written once at construction and never changes.
	local renderDesc = self.renderDesc
	renderDesc.colorAttachments[1].texture = texture:createView(self.emptyViewDesc)
	encoder:beginRendering(renderDesc)
	encoder:setPipeline(self.pipeline)
	encoder:setBindGroup(0, self.bindGroup)
	encoder:setViewport(0, 0, width, height)
	encoder:setVertexBuffer(0, self.vertexBuffer)
	encoder:setIndexBuffer(self.indexBuffer, "u16")
	encoder:drawIndexed(self.indexCount, 1, 0, 0, 0)
	encoder:endRendering()

	local commandBuffer = encoder:finish()
	self.device.queue:submit(commandBuffer, self.swapchain)
	self.device.queue:present(self.swapchain)
end

return Draw
