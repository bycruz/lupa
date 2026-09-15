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

--- Upper bound on the CPU-side index array. Quad geometry needs 6 per quad;
--- meshes add their own on top.
local MAX_INDICES = 262144

--- Quads the vertex buffer can hold. The index buffer is seeded with the quad
--- pattern for this many quads, so quad-only frames never rewrite it.
local MAX_QUADS = MAX_VERTICES / 4

--- Depth of the model matrix stack.
local MODEL_STACK_MAX = 32

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
		size = VertexArraySize * MAX_VERTICES,
		usages = { "VERTEX", "COPY_DST" }
	})

	local indexBuffer = device:createBuffer({
		size = IndexArraySize * MAX_INDICES,
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

	-- The fragment shader multiplies each quad's UV by u_uvScales[textureIndex].
	-- Uninitialised that is (0, 0), which collapses every sample to one texel,
	-- so seed all 256 slots with 1.
	local uvScales = ffi.new("float[512]")
	for i = 0, 511 do
		uvScales[i] = 1.0
	end
	device.queue:writeBuffer(uvScalesBuffer, 512 * 4, uvScales)

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

	-- Preallocated so pushModel/popModel never allocate.
	local modelStack = {}
	local modelIdentStack = {}
	for i = 1, MODEL_STACK_MAX do
		modelStack[i] = lpmath.mat4.identity()
		modelIdentStack[i] = true
	end

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
		indices = IndexArray(MAX_INDICES),
		modelStack = modelStack,
		modelIdentStack = modelIdentStack,
		modelDepth = 1,
		model = modelStack[1],
		modelIdentity = true,
		rotationScratch = lpmath.mat4.identity(),
		customView = false,
		camera = nil,
		meshIndexCount = 0,
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

--- Draw a rectangle. (x, y) is the bottom-left corner: the default 2D view is
--- orthographic with y increasing upward.
---@param x number
---@param y number
---@param w number
---@param h number
---@format disable-next
function Draw:rect(x, y, w, h)
	local verts = self.vertices
	local idxs  = self.indices
	local vc    = self.vertexCount
	local ic    = self.indexCount
	local r, g, b, a = self.curR, self.curG, self.curB, self.curA
	local tex   = self.curTexture
	local u0, v0, u1, v1 = self.texU0, self.texV0, self.texU1, self.texV1

	if vc > MAX_VERTICES - 4 then
		error("lupa: geometry buffers are full")
	end

	local v = verts[vc]
	v.x, v.y, v.z = x, y, 0
	v.u, v.v = u0, v1
	v.nx, v.ny, v.nz = 0, 0, 1
	v.r, v.g, v.b, v.a = r, g, b, a
	v.textureIndex = tex

	v = verts[vc + 1]
	v.x, v.y, v.z = x + w, y, 0
	v.u, v.v = u1, v1
	v.nx, v.ny, v.nz = 0, 0, 1
	v.r, v.g, v.b, v.a = r, g, b, a
	v.textureIndex = tex

	v = verts[vc + 2]
	v.x, v.y, v.z = x, y + h, 0
	v.u, v.v = u0, v0
	v.nx, v.ny, v.nz = 0, 0, 1
	v.r, v.g, v.b, v.a = r, g, b, a
	v.textureIndex = tex

	v = verts[vc + 3]
	v.x, v.y, v.z = x + w, y + h, 0
	v.u, v.v = u1, v0
	v.nx, v.ny, v.nz = 0, 0, 1
	v.r, v.g, v.b, v.a = r, g, b, a
	v.textureIndex = tex

	idxs[ic]     = vc
	idxs[ic + 1] = vc + 1
	idxs[ic + 2] = vc + 2
	idxs[ic + 3] = vc + 1
	idxs[ic + 4] = vc + 3
	idxs[ic + 5] = vc + 2

	self.vertexCount = vc + 4
	self.indexCount  = ic + 6
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

--- Unit UV sphere, cached per tessellation because a scene usually uses one.
local sphereCache = {}

---@param segments number
---@param rings number
---@return ffi.cdata* vertices, ffi.cdata* indices, number vertexCount, number indexCount
local function sphereMesh(segments, rings)
	local key = segments * 1024 + rings
	local hit = sphereCache[key]
	if hit then
		return hit.vertices, hit.indices, hit.vertexCount, hit.indexCount
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

	return entry.vertices, entry.indices, entry.vertexCount, entry.indexCount
end

--- Emit a mesh: scale, then the current model matrix, then the position.
--- The model matrix is applied on the CPU rather than through the `u_model`
--- uniform because the uniform is per-frame -- using it would force one draw
--- call per object instead of one for the whole frame.
---@param self lupa.Draw
---@param verts ffi.cdata*
---@param indices ffi.cdata*
---@param vcount number
---@param icount number
---@param px number
---@param py number
---@param pz number
---@param sx number
---@param sy number
---@param sz number
local function emitMesh(self, verts, indices, vcount, icount, px, py, pz, sx, sy, sz)
	local base = self.vertexCount
	local ic = self.indexCount

	if base + vcount > MAX_VERTICES or ic + icount > MAX_INDICES then
		error("lupa: geometry buffers are full; split the draw or raise MAX_VERTICES/MAX_INDICES")
	end

	local out = self.vertices
	local idxs = self.indices
	local r, g, b, a = self.curR, self.curG, self.curB, self.curA
	local tex = self.curTexture

	-- A non-default sampled rectangle remaps the mesh's own UVs. Checked once,
	-- outside the vertex loops, so ordinary draws pay nothing for it.
	local remapUV = not self.texDefault
	local ru0, rv0, ruSpan, rvSpan
	if remapUV then
		ru0, rv0 = self.texU0, self.texV0
		ruSpan, rvSpan = self.texU1 - self.texU0, self.texV1 - self.texV0
	end

	-- The transform / no-transform split is hoisted out of the vertex loop so
	-- each loop is a straight-line trace with no per-vertex branch. This is the
	-- hottest 3D path: it runs once per vertex of every mesh in the frame.
	if not self.modelIdentity then
		local e = self.model.m
		local m00, m01, m02, m03 = e[0], e[4], e[8], e[12]
		local m10, m11, m12, m13 = e[1], e[5], e[9], e[13]
		local m20, m21, m22, m23 = e[2], e[6], e[10], e[14]

		local j = 0
		for i = 0, vcount - 1 do
			local x, y, z = verts[j] * sx, verts[j + 1] * sy, verts[j + 2] * sz
			local nx, ny, nz = verts[j + 3], verts[j + 4], verts[j + 5]
			local u, w = verts[j + 6], verts[j + 7]
			j = j + 8
			if remapUV then
				u, w = ru0 + u * ruSpan, rv0 + w * rvSpan
			end

			local v = out[base + i]
			v.x = m00 * x + m01 * y + m02 * z + m03 + px
			v.y = m10 * x + m11 * y + m12 * z + m13 + py
			v.z = m20 * x + m21 * y + m22 * z + m23 + pz
			v.u, v.v = u, w
			-- Normals get the same rotation; for non-uniform scale this is an
			-- approximation, and the shader renormalises.
			v.nx = m00 * nx + m01 * ny + m02 * nz
			v.ny = m10 * nx + m11 * ny + m12 * nz
			v.nz = m20 * nx + m21 * ny + m22 * nz
			v.r, v.g, v.b, v.a = r, g, b, a
			v.textureIndex = tex
		end
	else
		local j = 0
		for i = 0, vcount - 1 do
			local v = out[base + i]
			v.x = verts[j] * sx + px
			v.y = verts[j + 1] * sy + py
			v.z = verts[j + 2] * sz + pz
			local u, w = verts[j + 6], verts[j + 7]
			if remapUV then
				u, w = ru0 + u * ruSpan, rv0 + w * rvSpan
			end
			v.u, v.v = u, w
			v.nx, v.ny, v.nz = verts[j + 3], verts[j + 4], verts[j + 5]
			v.r, v.g, v.b, v.a = r, g, b, a
			v.textureIndex = tex
			j = j + 8
		end
	end

	for i = 0, icount - 1 do
		idxs[ic] = base + indices[i]
		ic = ic + 1
	end

	self.vertexCount = base + vcount
	self.indexCount = ic
	self.meshIndexCount = self.meshIndexCount + icount
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
	emitMesh(self, CUBE_VERTICES, CUBE_INDICES, 24, 36, x, y, z, s, s, s)
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
	local verts, indices, vcount, icount = sphereMesh(segments, rings)
	local s = (radius or 1) * 2 -- the unit sphere has radius 0.5
	emitMesh(self, verts, indices, vcount, icount, x, y, z, s, s, s)
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
	emitMesh(self, mesh.vertices, mesh.indices, mesh.vertexCount, mesh.indexCount,
		x or 0, y or 0, z or 0, s, sy or s, sz or s)
end

--- Horizontal plane spanning `width` on X and `depth` on Z, centred on (x, y, z).
---@param x number
---@param y number
---@param z number
---@param width number?
---@param depth number?
function Draw:plane(x, y, z, width, depth)
	emitMesh(self, PLANE_VERTICES, PLANE_INDICES, 4, 6, x, y, z, width or 1, 1, depth or 1)
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
	self.vertexCount = 0
	self.indexCount = 0
	self.meshIndexCount = 0
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

	-- Preallocated so pushModel/popModel never allocate.
	local modelStack = {}
	local modelIdentStack = {}
	for i = 1, MODEL_STACK_MAX do
		modelStack[i] = lpmath.mat4.identity()
		modelIdentStack[i] = true
	end

	self.swapchain = swapchain
	self.depthBuffer = depthBuffer
	self.depthBufferView = depthBufferView
	self.renderDesc.depthStencilAttachment.texture = depthBufferView

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
	transforms.model = self.identityModel

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
	local encoder = self.swapchain:createCommandEncoder()
	encoder:writeBuffer(self.transformsBuffer, TransformsSize, transforms)
	encoder:writeBuffer(self.lightingBuffer, LightingSize, lighting)
	encoder:writeBuffer(self.vertexBuffer, VertexArraySize * self.vertexCount, self.vertices)
	-- Quad-only frames match the index pattern seeded at construction, so the
	-- upload is skipped. A frame that drew meshes wrote its own indices.
	if self.meshIndexCount > 0 then
		encoder:writeBuffer(self.indexBuffer, IndexArraySize * self.indexCount, self.indices)
	end

	if self.uvScalesDirty then
		encoder:writeBuffer(self.uvScalesBuffer, 512 * 4, self.uvScales)
		self.uvScalesDirty = false
	end

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
