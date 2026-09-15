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
---@field private renderDesc table
---@field private emptyViewDesc table
local Draw = {}
Draw.__index = Draw

local MAX_TEXTURES = 256
local MAX_TEXTURE_WIDTH = 512
local MAX_TEXTURE_HEIGHT = 512

--- Depth of the model matrix stack.
local MODEL_STACK_MAX = 32

ffi.cdef [[
    /* One instance of a mesh: the world matrix to apply to the mesh's own
       vertices, plus the per-draw state that differs between instances. The
       matrix is four vec4 columns, matching GLSL's mat4 constructor and the
       column-major layout the model stack already uses.

       uvRect is (u0, v0, spanU, spanV) for the sampled rectangle, which is what
       lets a draw made under setTextureRect join an instance batch instead of
       having the remap baked into its vertices.

       112 bytes, with the matrix columns and the uv rect each on a 16 byte
       boundary so the shader reads the array straight through. */
    typedef struct {
        float model[16];
        float r, g, b, a;
        float textureIndex;
        float uvU0, uvV0, uvSpanU, uvSpanV;
    } LupaInstance;

    /* One indexed draw, read from a buffer instead of written into the command
       stream. Layout matches VkDrawIndexedIndirectCommand and GL's
       DrawElementsIndirectCommand, so the same records drive either backend. */
    typedef struct {
        uint32_t indexCount;
        uint32_t instanceCount;
        uint32_t firstIndex;
        int32_t vertexOffset;
        uint32_t firstInstance;
    } LupaDrawRecord;

    /* Only the projection is a uniform: the world matrix is per instance. */
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

---@class lupa.draw.ffi.Lighting: ffi.cdata*
---@field lightDir number[]
---@field lightEnabled number
---@field lightColor number[]
---@field ambientColor number[]
---@field cameraPos number[]

---@type fun(count: number): ffi.cdata*
local InstanceArray = ffi.typeof("LupaInstance[?]")
local InstanceStride = ffi.sizeof("LupaInstance")

---@type fun(count: number): ffi.cdata*
local DrawRecordArray = ffi.typeof("LupaDrawRecord[?]")
local DrawRecordStride = ffi.sizeof("LupaDrawRecord")

--- Starting capacity of the per-frame instance array; it doubles like the
--- geometry arrays when a frame needs more.
local INITIAL_INSTANCE_CAPACITY = 1024

--- Starting size of the mesh arenas, which hold every mesh's vertices and
--- indices in one buffer each. Indirect draws share the bound vertex and index
--- buffers, so a mesh's position in the arena is what selects it.
local INITIAL_ARENA_VERTEX_BYTES = 4 * 1024 * 1024
local INITIAL_ARENA_INDEX_BYTES = 1024 * 1024

--- Starting capacity of the per-frame draw record array.
local INITIAL_DRAW_CAPACITY = 256

--- Reallocate a flat array so it holds at least `needed` elements, preserving
--- what is already in it. Doubling keeps a frame that grows repeatedly
--- amortised; the caller passes the element count, never a byte count.
---@param array ffi.cdata*
---@param capacity number current element count
---@param needed number required element count
---@param elementSize number bytes per element
---@param elementType fun(count: number): ffi.cdata*
---@return ffi.cdata* array
---@return number capacity
local function growArray(array, capacity, needed, elementSize, elementType)
	local grown = math.max(capacity, 1)
	while grown < needed do
		grown = grown * 2
	end

	local replacement = elementType(grown)
	ffi.copy(replacement, array, capacity * elementSize)

	return replacement, grown
end


---@type fun(proj: lupa.math.Mat4, model: lupa.math.Mat4): ffi.cdata*
local Transforms = ffi.typeof("LupaTransforms")
local TransformsSize = ffi.sizeof("LupaTransforms")

---@type fun(): lupa.draw.ffi.Lighting
local Lighting = ffi.typeof("LupaLighting")
local LightingSize = ffi.sizeof("LupaLighting")

local backend = os.getenv("BACKEND") or "vulkan"
local shaderType = backend == "vulkan" and "spirv" or "glsl"

--- Bytes of UV scale data: 256 texture slots of 2 floats.
local UV_SCALES_SIZE = 512 * 4

--- Write CPU data into a buffer, using whichever route the backend has.
---
--- A mapped buffer is written straight into its own memory with no command
--- recorded and nothing submitted. OpenGL buffers are not mapped, so they go
--- through the queue helper, which is also a direct upload (namedBufferSubData)
--- rather than a staging copy.
---@param device hood.Device
---@param buffer hood.Buffer
---@param size number
---@param data ffi.cdata*
---@param offset number? byte offset into the buffer
local function upload(device, buffer, size, data, offset)
	offset = offset or 0
	if buffer.isMapped then
		ffi.copy(buffer:mappedPointer(offset), data, size)
		return
	end
	device.queue:writeBuffer(buffer, size, data, offset)
end

--- One frame's worth of buffers.
---
--- Every buffer the CPU rewrites per frame lives here, and there is one set per
--- swapchain image. Sharing a single set would mean writing the geometry for
--- frame N+1 into the same memory a frame still in flight is reading, which is a
--- write-after-read hazard rather than a theoretical one: nothing orders the
--- CPU's write against the GPU's read of the previous submission.
---
--- The uniform buffers are per frame for the same reason, and their sizes are
--- exact now instead of a guessed 64 KB, which only ever needed to hold 128 and
--- 64 bytes.
--- One frame's worth of buffers.
---
--- Only the per-frame data lives here: the instance records, the indirect draw
--- commands that index into them, and the small uniform blocks. Every mesh's
--- vertices sit in the shared arenas instead, written once and never touched by
--- a frame.
---
--- Per frame slot, because writing a buffer an in-flight frame may still be
--- reading is a write-after-read hazard with nothing to order it.
---@param device hood.Device
---@param instanceCapacity number
---@param drawCapacity number
---@return table
local function createFrameSlot(device, instanceCapacity, drawCapacity)
	return {
		instanceBuffer = device:createBuffer({
			size = InstanceStride * instanceCapacity,
			usages = { "VERTEX", "COPY_DST" },
			mapped = true,
		}),
		indirectBuffer = device:createBuffer({
			size = DrawRecordStride * drawCapacity,
			usages = { "INDIRECT", "COPY_DST" },
			mapped = true,
		}),
		transformsBuffer = device:createBuffer({
			size = TransformsSize,
			usages = { "UNIFORM", "COPY_DST" },
			mapped = true,
		}),
		lightingBuffer = device:createBuffer({
			size = LightingSize,
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
	}
end

-- Forward declarations. The meshes and the instance appending live below the
-- Draw methods that use them, and Lua resolves a name when the function is
-- compiled, so a plain `local` further down would leave these as globals.
local appendInstance
local RECT_MESH

---@param window winit.Window
function Draw.new(window)
	local instance = hood.Instance.new({ backend = backend, flags = {} })
	local adapter = instance:requestAdapter({ powerPreference = "high-performance" })
	local device = adapter:requestDevice()

	local surface = instance:createSurface(window)
	local surfaceConfig = { presentMode = "immediate" }
	local swapchain = surface:configure(device, surfaceConfig)

	-- Meshes supply position, normal and uv (8 floats each); everything that
	-- varies per draw comes from the instance instead.
	local meshLayout = hood.VertexLayout.new()
		:withAttribute({ type = "f32", size = 3, offset = 0 })  -- location 0: position
		:withAttribute({ type = "f32", size = 2, offset = 24 }) -- location 1: uv
		:withAttribute({ type = "f32", size = 3, offset = 12 }) -- location 2: normal

	-- One element per instance: the world matrix, the colour and the texture
	-- index. The stride is stated rather than derived so it matches the 96 byte
	-- record the CPU writes, including its padding.
	local instanceLayout = hood.VertexLayout.new({ stride = InstanceStride })
		:withAttribute({ type = "f32", size = 4, offset = 0 })   -- location 3: model column 0
		:withAttribute({ type = "f32", size = 4, offset = 16 })  -- location 4
		:withAttribute({ type = "f32", size = 4, offset = 32 })  -- location 5
		:withAttribute({ type = "f32", size = 4, offset = 48 })  -- location 6
		:withAttribute({ type = "f32", size = 4, offset = 64 })  -- location 7: colour
		:withAttribute({ type = "f32", size = 1, offset = 80 })  -- location 8: texture index
		:withAttribute({ type = "f32", size = 4, offset = 96 })  -- location 9: sampled rect
		:withInstanceRate()

	-- One set of buffers per frame the swapchain can have in flight.
	local frameCount = swapchain.imageCount or 1
	local frames = {}
	for i = 1, frameCount do
		frames[i] = createFrameSlot(device, INITIAL_INSTANCE_CAPACITY, INITIAL_DRAW_CAPACITY)
	end

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

	local isVulkan = backend == "vulkan"

	local bindings = {
		transforms = 0,
		lighting = 1,
		centralTexture = 2,
		centralSampler = isVulkan and 3 or 2, -- separate for Vulkan, same unit for OpenGL
		uvScales = 4
	}

	local textureView = texture:createView({})

	-- The fragment shader multiplies each quad's UV by u_uvScales[textureIndex].
	-- Uninitialised that is (0, 0), which collapses every sample to one texel,
	-- so seed all 256 slots with 1.
	local uvScales = ffi.new("float[512]")
	for i = 0, 511 do
		uvScales[i] = 1.0
	end
	for i = 1, frameCount do
		upload(device, frames[i].uvScalesBuffer, UV_SCALES_SIZE, uvScales)
	end

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

	-- A bind group names concrete buffers, so each frame slot needs its own:
	-- sharing one bind group would point every frame at the same transforms and
	-- lighting buffers, which is exactly what the per-frame split avoids. Growth
	-- rebuilds it too, since the buffers it names are replaced.
	---@param slot table
	local function bindGroupFor(slot)
		local bgEntries = {
			{ binding = bindings.transforms,     type = "uniform-buffer", buffer = slot.transformsBuffer },
			{ binding = bindings.lighting,       type = "uniform-buffer", buffer = slot.lightingBuffer },
			{ binding = bindings.centralTexture, type = "texture",        texture = textureView },
			{ binding = bindings.uvScales,       type = "uniform-buffer", buffer = slot.uvScalesBuffer }
		}
		-- Sampler binds to same unit as texture in OpenGL, separate in Vulkan
		table.insert(bgEntries, { binding = bindings.centralSampler, type = "sampler", sampler = sampler })
		table.sort(bgEntries, function(a, b) return a.binding < b.binding end)

		return device:createBindGroup({
			layout = bindGroupLayout,
			entries = bgEntries
		})
	end

	for i = 1, frameCount do
		frames[i].bindGroup = bindGroupFor(frames[i])
	end

	local pipeline = device:createPipeline({
		layout = bindGroupLayout,
		vertex = {
			module = { type = shaderType, source = vertexShader },
			buffers = { meshLayout, instanceLayout }
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
		depthStencil = {
			format = "depth24plus",
			depthWriteEnabled = true,
			depthCompare = "less-equal"
		}
	})

	-- The mesh arenas, in a table so that growing them does not invalidate what
	-- the draw object holds: growth replaces the buffers and everything reads
	-- through here.
	local arena = {
		vertexBuffer = false,
		indexBuffer = false,
		vertexCapacity = INITIAL_ARENA_VERTEX_BYTES,
		indexCapacity = INITIAL_ARENA_INDEX_BYTES,
		vertexUsed = 0,
		indexUsed = 0,
		meshes = {},
	}

	arena.vertexBuffer = device:createBuffer({
		size = arena.vertexCapacity,
		usages = { "VERTEX", "COPY_DST" },
	})
	arena.indexBuffer = device:createBuffer({
		size = arena.indexCapacity,
		usages = { "INDEX", "COPY_DST" },
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


	--- Put a mesh in the arenas if it is not there yet.
	---
	--- Meshes are immutable and uploaded once. Growth allocates bigger buffers,
	--- re-uploads every placed mesh at the offset it already had, and destroys the
	--- old buffers after the queue drains, since frames in flight may still be
	--- reading them. Offsets survive growth, so nothing needs rewriting.
	---@param mesh table
	---@return number vertexBase in vertices, for vertexOffset
	---@return number indexBase in indices, for firstIndex
	local function placeMesh(mesh)
		local placement = mesh.arena
		if placement then
			return placement.vertexBase, placement.indexBase
		end

		local vertexBytes = mesh.vertexCount * 8 * 4
		local indexBytes = mesh.indexCount * 4

		local needVertex = arena.vertexUsed + vertexBytes
		local needIndex = arena.indexUsed + indexBytes

		if needVertex > arena.vertexCapacity or needIndex > arena.indexCapacity then
			while arena.vertexCapacity < needVertex do
				arena.vertexCapacity = arena.vertexCapacity * 2
			end
			while arena.indexCapacity < needIndex do
				arena.indexCapacity = arena.indexCapacity * 2
			end

			device.queue:waitIdle()

			local oldVertex, oldIndex = arena.vertexBuffer, arena.indexBuffer
			arena.vertexBuffer = device:createBuffer({
				size = arena.vertexCapacity,
				usages = { "VERTEX", "COPY_DST" },
			})
			arena.indexBuffer = device:createBuffer({
				size = arena.indexCapacity,
				usages = { "INDEX", "COPY_DST" },
			})

			for _, other in ipairs(arena.meshes) do
				local at = other.arena
				upload(device, arena.vertexBuffer, other.vertexCount * 8 * 4, other.vertices, at.vertexBytes)
				upload(device, arena.indexBuffer, other.indexCount * 4, other.indices, at.indexBytes)
			end

			oldVertex:destroy()
			oldIndex:destroy()
		end

		mesh.arena = {
			vertexBase = arena.vertexUsed / 32,
			indexBase = arena.indexUsed / 4,
			vertexBytes = arena.vertexUsed,
			indexBytes = arena.indexUsed,
		}
		arena.meshes[#arena.meshes + 1] = mesh

		upload(device, arena.vertexBuffer, vertexBytes, mesh.vertices, arena.vertexUsed)
		upload(device, arena.indexBuffer, indexBytes, mesh.indices, arena.indexUsed)

		arena.vertexUsed = arena.vertexUsed + vertexBytes
		arena.indexUsed = arena.indexUsed + indexBytes

		return mesh.arena.vertexBase, mesh.arena.indexBase
	end

	-- Preallocated so pushModel/popModel never allocate.
	local modelStack = {}
	local modelIdentStack = {}
	for i = 1, MODEL_STACK_MAX do
		modelStack[i] = lpmath.mat4.identity()
		modelIdentStack[i] = true
	end

	---@format disable-next
	return setmetatable({
		swapchain = swapchain,
		pipeline = pipeline,
		placeMesh = placeMesh,
		arena = arena,
		device = device,
		surface = surface,
		surfaceConfig = surfaceConfig,
		window = window,
		frames = frames,
		frameCount = frameCount,
		bindGroupFor = bindGroupFor,
		instanceCount = 0,
		instanceCapacity = INITIAL_INSTANCE_CAPACITY,
		instances = InstanceArray(INITIAL_INSTANCE_CAPACITY),
		drawRecordCapacity = INITIAL_DRAW_CAPACITY,
		drawRecords = DrawRecordArray(INITIAL_DRAW_CAPACITY),
		drawRecordCount = 0,
		lastRecordMesh = false,
		lastRecordTexture = -1,
		depthBuffer = depthBuffer,
		depthBufferView = depthBufferView,
		texture = texture,
		sampler = sampler,
		modelStack = modelStack,
		modelIdentStack = modelIdentStack,
		modelDepth = 1,
		model = modelStack[1],
		modelIdentity = true,
		rotationScratch = lpmath.mat4.identity(),
		customView = false,
		camera = nil,
		curR = 1, curG = 1, curB = 1, curA = 1,
		curTexture = -1,
		texU0 = 0, texV0 = 0, texU1 = 1, texV1 = 1,
		texDefault = true,
		textureLayers = 0,
		maxTextureWidth = MAX_TEXTURE_WIDTH,
		maxTextureHeight = MAX_TEXTURE_HEIGHT,
		uvScales = uvScales,
		uvScalesDirty = false,
		transforms = Transforms(),
		lighting = Lighting(),
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

--- Make room for more indirect draw records.
---@param count number
---@private
function Draw:reserveDrawRecords(count)
	if self.drawRecordCount + count <= self.drawRecordCapacity then
		return
	end

	self.drawRecords, self.drawRecordCapacity = growArray(
		self.drawRecords, self.drawRecordCapacity, self.drawRecordCount + count,
		DrawRecordStride, DrawRecordArray)
end

---@param count number
---@private
function Draw:reserveInstances(count)
	if self.instanceCount + count <= self.instanceCapacity then
		return
	end

	self.instances, self.instanceCapacity = growArray(
		self.instances, self.instanceCapacity, self.instanceCount + count,
		InstanceStride, InstanceArray)
end

---@param r number
---@param g number
---@param b number
---@param a number?
function Draw:setColor(r, g, b, a)
	self.curR = r; self.curG = g; self.curB = b; self.curA = a or 1.0
end

--- Draw a rectangle. (x, y) is the bottom-left corner: the default 2D view is
--- orthographic with y increasing upward.
---
--- A rectangle is one instance of a unit quad, so it costs a 112 byte record
--- rather than four vertices, and consecutive rectangles share a single draw
--- command.
---@param x number
---@param y number
---@param w number
---@param h number
---@format disable-next
function Draw:rect(x, y, w, h)
	local instance = appendInstance(self, RECT_MESH)
	local m = instance.model

	-- The quad is centred and unit sized, so the matrix is its size and centre.
	-- Rectangles do not go through the model stack, exactly as before.
	m[0], m[1], m[2], m[3] = w, 0, 0, 0
	m[4], m[5], m[6], m[7] = 0, h, 0, 0
	m[8], m[9], m[10], m[11] = 0, 0, 1, 0
	m[12], m[13], m[14], m[15] = x + w * 0.5, y + h * 0.5, 0, 1
end

--- Make room for more indirect draw records.
---@param count number
---@private
function Draw:reserveDrawRecords(count)
	if self.drawRecordCount + count <= self.drawRecordCapacity then
		return
	end

	self.drawRecords, self.drawRecordCapacity = growArray(
		self.drawRecords, self.drawRecordCapacity, self.drawRecordCount + count,
		DrawRecordStride, DrawRecordArray)
end

---@param count number
---@private
function Draw:reserveInstances(count)
	if self.instanceCount + count <= self.instanceCapacity then
		return
	end

	self.instances, self.instanceCapacity = growArray(
		self.instances, self.instanceCapacity, self.instanceCount + count,
		InstanceStride, InstanceArray)
end


-- ===========================================================================
-- Meshes
-- ===========================================================================

--- Unit meshes are flat arrays of x, y, z, nx, ny, nz per vertex, centred on
--- the origin: the draw call supplies position and scale. Faces are wound
--- counter-clockwise as seen from outside.

---@type number[]
local CUBE_VERTICES = ffi.new("float[192]", {
	-- +Z
	-0.5, -0.5,  0.5,  0,  0,  1,  0, 1,
	 0.5, -0.5,  0.5,  0,  0,  1,  1, 1,
	 0.5,  0.5,  0.5,  0,  0,  1,  1, 0,
	-0.5,  0.5,  0.5,  0,  0,  1,  0, 0,
	-- -Z
	 0.5, -0.5, -0.5,  0,  0, -1,  0, 1,
	-0.5, -0.5, -0.5,  0,  0, -1,  1, 1,
	-0.5,  0.5, -0.5,  0,  0, -1,  1, 0,
	 0.5,  0.5, -0.5,  0,  0, -1,  0, 0,
	-- +X
	 0.5, -0.5,  0.5,  1,  0,  0,  0, 1,
	 0.5, -0.5, -0.5,  1,  0,  0,  1, 1,
	 0.5,  0.5, -0.5,  1,  0,  0,  1, 0,
	 0.5,  0.5,  0.5,  1,  0,  0,  0, 0,
	-- -X
	-0.5, -0.5, -0.5, -1,  0,  0,  0, 1,
	-0.5, -0.5,  0.5, -1,  0,  0,  1, 1,
	-0.5,  0.5,  0.5, -1,  0,  0,  1, 0,
	-0.5,  0.5, -0.5, -1,  0,  0,  0, 0,
	-- +Y
	-0.5,  0.5,  0.5,  0,  1,  0,  0, 1,
	 0.5,  0.5,  0.5,  0,  1,  0,  1, 1,
	 0.5,  0.5, -0.5,  0,  1,  0,  1, 0,
	-0.5,  0.5, -0.5,  0,  1,  0,  0, 0,
	-- -Y
	-0.5, -0.5, -0.5,  0, -1,  0,  0, 1,
	 0.5, -0.5, -0.5,  0, -1,  0,  1, 1,
	 0.5, -0.5,  0.5,  0, -1,  0,  1, 0,
	-0.5, -0.5,  0.5,  0, -1,  0,  0, 0,
})

---@type ffi.cdata*
local CUBE_INDICES = ffi.new("int[36]", {
	 0,  1,  2,  0,  2,  3,
	 4,  5,  6,  4,  6,  7,
	 8,  9, 10,  8, 10, 11,
	12, 13, 14, 12, 14, 15,
	16, 17, 18, 16, 18, 19,
	20, 21, 22, 20, 22, 23,
})

---@type ffi.cdata*
local PLANE_VERTICES = ffi.new("float[32]", {
	-0.5, 0,  0.5,  0, 1, 0,  0, 1,
	 0.5, 0,  0.5,  0, 1, 0,  1, 1,
	 0.5, 0, -0.5,  0, 1, 0,  1, 0,
	-0.5, 0, -0.5,  0, 1, 0,  0, 0,
})

---@type ffi.cdata*
local PLANE_INDICES = ffi.new("int[6]", { 0, 1, 2, 0, 2, 3 })

--- The built-in primitives are meshes like any other, so they take the same
--- instanced path: a run of cubes or spheres is one instanced draw rather than
--- a CPU copy of every vertex of every one of them.
---@param vertices ffi.cdata*
---@param indices ffi.cdata*
---@param vertexCount number
---@param indexCount number
---@return table
local function meshOf(vertices, indices, vertexCount, indexCount)
	return {
		vertices = vertices,
		indices = indices,
		vertexCount = vertexCount,
		indexCount = indexCount,
	}
end

--- A unit quad for 2D rectangles: centred on the origin, with v = 0 along the
--- top edge, matching how the old per-vertex path wrote a rectangle.
RECT_MESH = meshOf(
	ffi.new("float[32]", {
		-0.5, -0.5, 0,  0, 0, 1,  0, 1,
		 0.5, -0.5, 0,  0, 0, 1,  1, 1,
		-0.5,  0.5, 0,  0, 0, 1,  0, 0,
		 0.5,  0.5, 0,  0, 0, 1,  1, 0,
	}),
	ffi.new("int[6]", { 0, 1, 2, 1, 3, 2 }),
	4, 6)

local CUBE_MESH = meshOf(CUBE_VERTICES, CUBE_INDICES, 24, 36)
local PLANE_MESH = meshOf(PLANE_VERTICES, PLANE_INDICES, 4, 6)

--- Unit UV sphere, cached per tessellation because a scene usually uses one.
local sphereCache = {}

---@param segments number
---@param rings number
---@return table mesh
local function sphereMesh(segments, rings)
	local key = segments * 1024 + rings
	local hit = sphereCache[key]
	if hit then
		return hit
	end

	local vcount = (rings + 1) * (segments + 1)
	local icount = rings * segments * 6
	local verts = ffi.new("float[?]", vcount * 8)
	local indices = ffi.new("int[?]", icount)
	local stride = segments + 1

	local v = 0
	for ring = 0, rings do
		local phi = math.pi * ring / rings
		local y = math.cos(phi) * 0.5
		local radius = math.sin(phi) * 0.5
		for seg = 0, segments do
			local theta = 2 * math.pi * seg / segments
			local x = math.cos(theta) * radius
			local z = math.sin(theta) * radius
			verts[v] = x
			verts[v + 1] = y
			verts[v + 2] = z
			-- On a sphere centred at the origin the normal is the direction
			-- from the centre, which for radius 0.5 is the position doubled.
			verts[v + 3] = x * 2
			verts[v + 4] = y * 2
			verts[v + 5] = z * 2
			-- Equirectangular UVs, so a plain image wraps around the sphere.
			verts[v + 6] = seg / segments
			verts[v + 7] = ring / rings
			v = v + 8
		end
	end

	local k = 0
	for ring = 0, rings - 1 do
		for seg = 0, segments - 1 do
			local aa = ring * stride + seg
			local bb = aa + stride
			indices[k] = aa
			indices[k + 1] = bb
			indices[k + 2] = aa + 1
			indices[k + 3] = aa + 1
			indices[k + 4] = bb
			indices[k + 5] = bb + 1
			k = k + 6
		end
	end

	local entry = {
		vertices = verts,
		indices = indices,
		vertexCount = vcount,
		indexCount = icount,
	}
	sphereCache[key] = entry

	return entry
end

--- Add one instance of a mesh to the frame, returning the record to fill in.
---
--- Consecutive draws of the same mesh under the same texture extend a single
--- draw command, so a frame of rects — or a loop over entities sharing a mesh —
--- becomes one record covering all of them. Anything that differs per draw
--- (transform, colour, sampled rectangle) travels in the instance record, so
--- only a different mesh or texture starts a new one.
---@param self lupa.Draw
---@param mesh table
---@return ffi.cdata* LupaInstance
function appendInstance(self, mesh)
	self:reserveInstances(1)

	local instance = self.instances[self.instanceCount]
	instance.r, instance.g, instance.b, instance.a = self.curR, self.curG, self.curB, self.curA
	instance.textureIndex = self.curTexture
	instance.uvU0, instance.uvV0 = self.texU0, self.texV0
	instance.uvSpanU, instance.uvSpanV = self.texU1 - self.texU0, self.texV1 - self.texV0

	local vertexBase, indexBase = self.placeMesh(mesh)
	local count = self.drawRecordCount

	-- Extend the previous command when it draws the same mesh and the instances
	-- are still contiguous, which they always are: records are appended in the
	-- order the instances were.
	-- The batch check compares against the draw's own state: the record is a
	-- plain C struct and carries only the fields the GPU reads.
	if count > 0 and self.lastRecordMesh == mesh and self.lastRecordTexture == self.curTexture then
		local record = self.drawRecords[count - 1]
		record.instanceCount = record.instanceCount + 1
	else
		self:reserveDrawRecords(1)

		local record = self.drawRecords[count]
		record.indexCount = mesh.indexCount
		record.instanceCount = 1
		record.firstIndex = indexBase
		record.vertexOffset = vertexBase
		record.firstInstance = self.instanceCount

		self.drawRecordCount = count + 1
		self.lastRecordMesh = mesh
		self.lastRecordTexture = self.curTexture
	end

	self.instanceCount = self.instanceCount + 1

	return instance
end

--- Draw one copy of a mesh: scale, then the current model matrix, then the
--- position.
---
--- The world matrix is built on the CPU and applied by the vertex shader, which
--- is what makes a copy cost one instance record instead of a copy of every
--- vertex. `T(position) * model * S(scale)` is the same transform the old
--- per-vertex path computed, so meshes land identically.
---@param self lupa.Draw
---@param mesh table
---@param px number
---@param py number
---@param pz number
---@param sx number
---@param sy number
---@param sz number
local function emitMesh(self, mesh, px, py, pz, sx, sy, sz)
	if mesh.vertexCount == 0 or mesh.indexCount == 0 then
		return
	end

	local instance = appendInstance(self, mesh)
	local e = self.model.m

	instance.model[0], instance.model[1], instance.model[2], instance.model[3] =
		e[0] * sx, e[1] * sx, e[2] * sx, e[3] * sx
	instance.model[4], instance.model[5], instance.model[6], instance.model[7] =
		e[4] * sy, e[5] * sy, e[6] * sy, e[7] * sy
	instance.model[8], instance.model[9], instance.model[10], instance.model[11] =
		e[8] * sz, e[9] * sz, e[10] * sz, e[11] * sz
	instance.model[12], instance.model[13], instance.model[14], instance.model[15] =
		e[12] + px, e[13] + py, e[14] + pz, e[15]
end
-- ===========================================================================
-- 2D/3D camera
-- ===========================================================================

--- Accept {x=,y=,z=} or {x,y,z}, falling back per component.
---@param t table|nil
---@return number, number, number
local function xyz(t, dx, dy, dz)
	if type(t) ~= "table" then
		return dx, dy, dz
	end
	return t.x or t[1] or dx, t.y or t[2] or dy, t.z or t[3] or dz
end

---@return lupa.math.Vec3
local function toVec3(t, dx, dy, dz)
	local x, y, z = xyz(t, dx, dy, dz)
	return lpmath.vec3.new(x, y, z)
end

--- Point a perspective camera at a target, replacing the default 2D
--- orthographic view until setOrtho() is called.
---
--- The camera only sets the view-projection for the frame; it does not change
--- how geometry is submitted, so 2D and 3D draws can be mixed freely.
---@param t { position: table, target: table?, up: table?, fov: number?, near: number?, far: number? }
function Draw:setCamera(t)
	assert(type(t) == "table" and t.position ~= nil, "setCamera requires { position = { x, y, z } }")
	self.camera = t

	local eye = toVec3(t.position, 0, 0, 0)
	local target = toVec3(t.target, 0, 0, 0)
	local up = toVec3(t.up, 0, 1, 0)

	local aspect = self.window.width / self.window.height
	local view = lpmath.mat4.lookAt(eye, target, up)
	local proj = lpmath.mat4.perspective(
		t.fov or (math.pi / 3), aspect, t.near or 0.1, t.far or 1000)

	self.transforms.viewProj = lpmath.mat4.mul(proj, view)
	self.customView = true
	self.projWidth, self.projHeight = nil, nil

	-- Specular highlights need the eye position.
	local light = self.lighting
	light.cameraPos[0] = eye.x
	light.cameraPos[1] = eye.y
	light.cameraPos[2] = eye.z
end

--- Supply the view-projection matrix directly.
---@param m lupa.math.Mat4
function Draw:setViewProjection(m)
	self.transforms.viewProj = m
	self.customView = true
	self.camera = nil
	self.projWidth, self.projHeight = nil, nil
end

--- Return to the default 2D orthographic view.
function Draw:setOrtho()
	self.customView = false
	self.camera = nil
	self.projWidth, self.projHeight = nil, nil
end

-- ===========================================================================
-- Model transform
-- ===========================================================================

--- Reset the stack to a single identity matrix.
function Draw:resetModel()
	local e = self.modelStack[1].m
	e[0], e[1], e[2], e[3] = 1, 0, 0, 0
	e[4], e[5], e[6], e[7] = 0, 1, 0, 0
	e[8], e[9], e[10], e[11] = 0, 0, 1, 0
	e[12], e[13], e[14], e[15] = 0, 0, 0, 1

	self.modelDepth = 1
	self.model = self.modelStack[1]
	for i = 1, MODEL_STACK_MAX do
		self.modelIdentStack[i] = true
	end
	self.modelIdentity = true
end

--- Save the current transform and start a nested one.
function Draw:pushModel()
	local depth = self.modelDepth + 1
	if depth > MODEL_STACK_MAX then
		error("lupa: model matrix stack overflow (max " .. MODEL_STACK_MAX .. ")")
	end

	local dst, src = self.modelStack[depth].m, self.modelStack[depth - 1].m
	for i = 0, 15 do
		dst[i] = src[i]
	end

	self.modelDepth = depth
	self.model = self.modelStack[depth]
	self.modelIdentStack[depth] = self.modelIdentStack[depth - 1]
end

--- Restore the transform saved by the matching pushModel.
function Draw:popModel()
	local depth = self.modelDepth
	if depth <= 1 then
		return
	end
	self.modelDepth = depth - 1
	self.model = self.modelStack[depth - 1]
	self.modelIdentity = self.modelIdentStack[depth - 1]
end

---@param x number
---@param y number
---@param z number
function Draw:translate(x, y, z)
	local e = self.model.m
	e[12] = e[0] * x + e[4] * y + e[8] * z + e[12]
	e[13] = e[1] * x + e[5] * y + e[9] * z + e[13]
	e[14] = e[2] * x + e[6] * y + e[10] * z + e[14]
	e[15] = e[3] * x + e[7] * y + e[11] * z + e[15]
	self.modelIdentity = false
end

---@param x number
---@param y number? defaults to x
---@param z number? defaults to x
function Draw:scale(x, y, z)
	y = y or x
	z = z or x
	local e = self.model.m
	e[0], e[1], e[2], e[3] = e[0] * x, e[1] * x, e[2] * x, e[3] * x
	e[4], e[5], e[6], e[7] = e[4] * y, e[5] * y, e[6] * y, e[7] * y
	e[8], e[9], e[10], e[11] = e[8] * z, e[9] * z, e[10] * z, e[11] * z
	self.modelIdentity = false
end

--- Rotate about an axis, defaulting to +Y.
---@param angle number radians
---@param x number?
---@param y number?
---@param z number?
function Draw:rotate(angle, x, y, z)
	if x == nil and y == nil and z == nil then
		x, y, z = 0, 1, 0
	end
	lpmath.mat4.rotateInto(self.rotationScratch, angle, x or 0, y or 0, z or 0)
	lpmath.mat4.mulInto(self.model, self.model, self.rotationScratch)
	self.modelIdentity = false
end

-- ===========================================================================
-- 3D primitives
-- ===========================================================================

--- Axis-aligned cube of edge `size`, centred on (x, y, z) before the model
--- transform is applied.
---@param x number
---@param y number
---@param z number
---@param size number?
function Draw:cube(x, y, z, size)
	local s = size or 1
	emitMesh(self, CUBE_MESH, x, y, z, s, s, s)
end

--- UV sphere of radius `radius` centred on (x, y, z).
---@param x number
---@param y number
---@param z number
---@param radius number?
---@param segments number? longitude divisions, default 24
function Draw:sphere(x, y, z, radius, segments)
	segments = segments or 24
	local rings = math.max(2, math.floor(segments / 2))
	local mesh = sphereMesh(segments, rings)
	local s = (radius or 1) * 2 -- the unit sphere has radius 0.5
	emitMesh(self, mesh, x, y, z, s, s, s)
end

--- Draw a mesh built with Draw:createMesh or loaded with Assets:obj, at a
--- position, optionally scaled. The current model matrix and colour apply as
--- they do for the built-in primitives.
---@param mesh lupa.Mesh
---@param x number?
---@param y number?
---@param z number?
---@param sx number?
---@param sy number?
---@param sz number?
function Draw:mesh(mesh, x, y, z, sx, sy, sz)
	local s = sx or 1
	emitMesh(self, mesh, x or 0, y or 0, z or 0, s, sy or s, sz or s)
end

--- Horizontal plane spanning `width` on X and `depth` on Z, centred on (x, y, z).
---@param x number
---@param y number
---@param z number
---@param width number?
---@param depth number?
function Draw:plane(x, y, z, width, depth)
	emitMesh(self, PLANE_MESH, x, y, z, width or 1, 1, depth or 1)
end

-- ===========================================================================
-- Lighting
-- ===========================================================================

--- Enable Blinn-Phong shading for everything drawn afterwards, including 2D
--- rects (whose normals all face +Z). Off by default.
---@param t { direction: table, color: table?, ambient: table? }
function Draw:setLight(t)
	local light = self.lighting

	local dx, dy, dz = xyz(t.direction, -0.5, -1, -0.3)
	light.lightDir[0], light.lightDir[1], light.lightDir[2] = dx, dy, dz

	local cr, cg, cb = xyz(t.color, 1, 1, 1)
	light.lightColor[0], light.lightColor[1], light.lightColor[2] = cr, cg, cb

	local ar, ag, ab = xyz(t.ambient, 0.2, 0.2, 0.2)
	light.ambientColor[0], light.ambientColor[1], light.ambientColor[2] = ar, ag, ab

	light.lightEnabled = 1.0
end

--- Back to unlit: vertex colours are used directly.
function Draw:clearLight()
	self.lighting.lightEnabled = 0.0
end

-- ===========================================================================
-- Textures
-- ===========================================================================

--- Upload RGBA8 pixels into the next free layer of the texture array and return
--- the layer index. `pixels` must be width * height * 4 bytes.
---
--- The array is fixed at MAX_TEXTURES layers of MAX_TEXTURE_WIDTH x
--- MAX_TEXTURE_HEIGHT; larger images have to be scaled down before they get
--- here (Assets:image does that for you).
---@param width number
---@param height number
---@param pixels ffi.cdata*
---@return number layer
function Draw:addTexture(width, height, pixels)
	local layer = self.textureLayers
	if layer >= MAX_TEXTURES then
		error("lupa: texture array is full (" .. MAX_TEXTURES .. " layers)")
	end
	if width > MAX_TEXTURE_WIDTH or height > MAX_TEXTURE_HEIGHT then
		error(string.format(
			"lupa: texture %dx%d exceeds the %dx%d layer size",
			width, height, MAX_TEXTURE_WIDTH, MAX_TEXTURE_HEIGHT))
	end

	self.textureLayers = layer + 1
	self.device.queue:writeTexture(self.texture, {
		width = width,
		height = height,
		layer = layer,
		bytesPerRow = width * 4,
	}, pixels)

	return layer
end

--- Draw everything after this with `texture` sampled. Accepts a texture handle
--- or a raw layer index; nil goes back to untextured.
---@param texture table|number|nil
function Draw:setTexture(texture)
	if texture == nil then
		self.curTexture = -1
	elseif type(texture) == "number" then
		self.curTexture = texture
	else
		self.curTexture = texture.layer
	end
	self.texU0, self.texV0, self.texU1, self.texV1 = 0, 0, 1, 1
	self.texDefault = true
end

--- Stop sampling a texture: shapes go back to flat vertex colour.
function Draw:clearTexture()
	self.curTexture = -1
	self.texU0, self.texV0, self.texU1, self.texV1 = 0, 0, 1, 1
	self.texDefault = true
end

--- Choose which part of the texture maps onto each shape. `(u0, v0)` is the
--- top-left of the source rectangle and `(u1, v1)` the bottom-right, in image
--- coordinates.
---
---   draw:setTextureRect(0.25, 0.0, 0.5, 0.5)   -- one cell of a sprite sheet
---   draw:setTextureRect(0, 0, 8, 4)            -- tile 8 by 4
---
--- Values past 1 repeat rather than clamp, because the sampler address mode is
--- repeat, so tiling is simply a rectangle larger than the texture.
---
--- Unlike the texture itself, this is per draw call: a sheet can be sliced into
--- as many different cells as you like within one frame.
---@param u0 number
---@param v0 number
---@param u1 number
---@param v1 number
function Draw:setTextureRect(u0, v0, u1, v1)
	self.texU0, self.texV0, self.texU1, self.texV1 = u0, v0, u1, v1
	self.texDefault = (u0 == 0 and v0 == 0 and u1 == 1 and v1 == 1)
end

function Draw:line()
end

---@private
function Draw:beginFrame()
	self.instanceCount = 0
	self.drawRecordCount = 0
	self.lastRecordMesh = false
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

	-- The reconfigured swapchain can come back with a different number of
	-- images, which changes how many frames can be in flight. Each of those needs
	-- its own buffers, and an index past the end of the array would otherwise
	-- silently fall back to slot 1 and reintroduce the hazard the split avoids.
	if (swapchain.imageCount or 1) ~= self.frameCount then
		self:_rebuildFrames(self.instanceCapacity, self.drawRecordCapacity)
	end

	-- Force the projection to be rebuilt for the new size, and re-derive the
	-- camera so its aspect ratio tracks the window.
	self.projWidth, self.projHeight = nil, nil
	if self.camera then
		self:setCamera(self.camera)
	end

	if oldDepthView then
		oldDepthView:destroy()
	end
	if oldDepth then
		oldDepth:destroy()
	end
end

--- Rebuild every frame slot at a new capacity, or for a new frame count.
---
--- Buffers cannot be resized, so this creates new ones and drops the old. Every
--- slot is rebuilt together rather than just the one being drawn, so the slots
--- stay interchangeable, and the old buffers are only dropped after the queue
--- drains: frames in flight may still be reading them. Growth happens when the
--- frame size doubles, so the stall is a one-off rather than per frame.
---@param instanceCapacity number
---@param drawCapacity number
---@private
function Draw:_rebuildFrames(instanceCapacity, drawCapacity)
	local device = self.device
	local frameCount = self.swapchain.imageCount or 1

	device.queue:waitIdle()

	local frames = {}
	for i = 1, frameCount do
		local slot = createFrameSlot(device, instanceCapacity, drawCapacity)

		-- A fresh uv scales buffer starts as zeroes, which would collapse every
		-- textured sample to one texel, so the current scales are re-uploaded.
		-- The bind group names this slot's uniform buffers, so it is rebuilt
		-- alongside them.
		upload(device, slot.uvScalesBuffer, UV_SCALES_SIZE, self.uvScales)
		slot.bindGroup = self.bindGroupFor(slot)
		frames[i] = slot
	end

	if self.frames then
		for _, old in ipairs(self.frames) do
			old.bindGroup:destroy()
			old.instanceBuffer:destroy()
			old.indirectBuffer:destroy()
			old.transformsBuffer:destroy()
			old.lightingBuffer:destroy()
			old.uvScalesBuffer:destroy()
		end
	end

	self.frames = frames
	self.frameCount = frameCount
end

---@private
function Draw:ensureGpuCapacity()
	local slot = self.frames[1]
	if self.instanceCapacity <= slot.instanceCapacity
		and self.drawRecordCapacity <= slot.drawCapacity
	then
		return
	end

	self:_rebuildFrames(self.instanceCapacity, self.drawRecordCapacity)
end

---@private
function Draw:endFrame()
	-- The default 2D orthographic projection only depends on the window size, so
	-- it is rebuilt only when that changes. A camera or an explicit matrix owns
	-- viewProj instead, and lighting is the caller's choice.
	local width, height = self.window.width, self.window.height
	local transforms = self.transforms
	if not self.customView then
		if self.projWidth ~= width or self.projHeight ~= height then
			self.projWidth, self.projHeight = width, height
			transforms.viewProj = lpmath.mat4.ortho(0, width, 0, height, -1, 1)
		end
	end
	local lighting = self.lighting

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
	--
	-- Growth comes first because it can submit its own work and wait for the
	-- queue to drain, which is best done before this frame's command buffer
	-- starts recording.
	self:ensureGpuCapacity()

	-- Which swapchain image this frame is rendering into, which is also the slot
	-- whose fence getCurrentTexture just waited on. That wait is what makes it
	-- safe to write this slot's buffers from the CPU: the previous frame that
	-- used them has finished.
	local slot = self.frames[self.swapchain.currentFrame or 1] or self.frames[1]

	local encoder = self.swapchain:createCommandEncoder()

	-- The frame's data is nothing but instances and the draw commands that index
	-- into them; every mesh's geometry was written to the arenas once.
	encoder:writeBuffer(slot.transformsBuffer, TransformsSize, transforms)
	encoder:writeBuffer(slot.lightingBuffer, LightingSize, lighting)
	if self.instanceCount > 0 then
		encoder:writeBuffer(slot.instanceBuffer, InstanceStride * self.instanceCount, self.instances)
		encoder:writeBuffer(slot.indirectBuffer, DrawRecordStride * self.drawRecordCount, self.drawRecords)
	end

	if self.uvScalesDirty then
		encoder:writeBuffer(slot.uvScalesBuffer, UV_SCALES_SIZE, self.uvScales)
		self.uvScalesDirty = false
	end

	local renderDesc = self.renderDesc
	renderDesc.colorAttachments[1].texture = texture:createView(self.emptyViewDesc)
	encoder:beginRendering(renderDesc)
	encoder:setViewport(0, 0, width, height)

	-- The pipeline is set even for an empty frame: hood begins the render pass
	-- when the pipeline is bound, so skipping it would leave endRendering ending a
	-- pass that never started.
	encoder:setPipeline(self.pipeline)
	encoder:setBindGroup(0, slot.bindGroup)

	if self.drawRecordCount > 0 then
		-- The whole frame, one call: every mesh and quad is an instance in the
		-- shared arenas, so the commands differ only in what they read. They are
		-- issued in the order the draws were, which is what keeps the frame in
		-- submission order without any grouping decisions.
		encoder:setVertexBuffer(0, self.arena.vertexBuffer)
		encoder:setVertexBuffer(1, slot.instanceBuffer)
		encoder:setIndexBuffer(self.arena.indexBuffer, "u32")
		encoder:drawIndexedIndirect(slot.indirectBuffer, 0, self.drawRecordCount, DrawRecordStride)
	end

	encoder:endRendering()

	local commandBuffer = encoder:finish()
	self.device.queue:submit(commandBuffer, self.swapchain)
	self.device.queue:present(self.swapchain)
end

return Draw
