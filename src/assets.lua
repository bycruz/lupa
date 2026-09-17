local ffi = require("ffi")

local obj = require("lupa.obj")
local png = require("lupa.png")

---@type ffi.ctype* float[?]
local floatArray = ffi.typeof("float[?]")

---@type ffi.ctype* int[?]
local intArray = ffi.typeof("int[?]")

---@type ffi.ctype* uint8_t[?]
local byteArray = ffi.typeof("uint8_t[?]")

---@type ffi.cdata*
local noIndices = ffi.new("int[0]")

---@class lupa.Texture
---@field layer number index into the texture array, as used by the shader
---@field width number
---@field height number
---@field emission number 0 to 1 of the texture's own colour added to what lights it
---@field cutout boolean true when only texels over half an alpha are drawn
local Texture = {}
Texture.__index = Texture

---@type fun(layer: number, width: number, height: number, options: lupa.TextureOptions?): lupa.Texture
function Texture.new(layer, width, height, options)
	return setmetatable({
		layer = layer,
		width = width,
		height = height,
		emission = options and options.emission or 0,
		cutout = (options and options.cutout) and true or false,
	}, Texture)
end

local VERTEX_FLOATS = 8
local TILED_VERTEX_FLOATS = 9

local HEADROOM = 1.25
local MINIMUM_VERTEX_FLOATS = 1024
local MINIMUM_INDICES = 1024

---@class lupa.Mesh
---@field vertices ffi.cdata* flat, `stride` floats per vertex: x, y, z, nx, ny, nz, u, v, and a tile
---@field indices ffi.cdata* flat, 0-based triangle indices
---@field stride number 8 floats per vertex, or 9 with a texture tile at the end
---@field vertexCount number
---@field indexCount number
---@field vertexCapacity number floats the vertex array holds
---@field indexCapacity number indices the index array holds
---@field changed boolean? set by update, cleared when the draw re-uploads it
---@field positionScale number? what one unit of a stored vertex position is worth
---@field uvScale number? what one unit of a stored vertex uv is worth
local Mesh = {}
Mesh.__index = Mesh

---@type fun(vertices: number[], indices: number[]?, stride: number?): lupa.Mesh
function Mesh.new(vertices, indices, stride)
	local mesh = setmetatable({
		vertices = false,
		indices = false,
		stride = stride or VERTEX_FLOATS,
		vertexCount = 0,
		indexCount = 0,
		vertexCapacity = 0,
		indexCapacity = 0,
	}, Mesh)

	mesh:update(vertices, indices, stride)

	return mesh
end

--- safety: the draw re-uploads a changed mesh the next time it draws it, and
--- reuses the space the mesh already holds while the new geometry fits there
---@type fun(self: lupa.Mesh, vertices: number[], indices: number[]?, stride: number?)
function Mesh:update(vertices, indices, stride)
	stride = stride or VERTEX_FLOATS
	if stride ~= VERTEX_FLOATS and stride ~= TILED_VERTEX_FLOATS then
		error("lupa: a mesh vertex is 8 floats, or 9 with a texture tile; got a stride of " .. stride)
	end
	if #vertices % stride ~= 0 then
		error(string.format("lupa: mesh vertices must be %d floats each; got %d", stride, #vertices))
	end

	self.vertices = floatArray(#vertices, vertices)
	self.indices = indices and intArray(#indices, indices) or noIndices
	self.stride = stride
	self.vertexCount = #vertices / stride
	self.indexCount = indices and #indices or 0
	self.vertexCapacity = #vertices
	self.indexCapacity = indices and #indices or 0
	self.changed = true
end

---@type fun(self: lupa.Mesh, vertices: ffi.cdata*, vertexCount: number, indices: ffi.cdata*?, indexCount: number, stride: number?)
function Mesh:updateFromData(vertices, vertexCount, indices, indexCount, stride)
	stride = stride or VERTEX_FLOATS
	local floats = vertexCount * stride

	-- safety: room to spare rather than a power of two, because a world holds thousands
	-- of these and doubling from one wastes most of what it holds
	if self.vertexCapacity < floats then
		local capacity = math.max(HEADROOM * floats, MINIMUM_VERTEX_FLOATS)
		self.vertices = floatArray(capacity)
		self.vertexCapacity = capacity
	end

	if self.indexCapacity < indexCount then
		local capacity = math.max(HEADROOM * indexCount, MINIMUM_INDICES)
		self.indices = intArray(capacity)
		self.indexCapacity = capacity
	end

	if floats > 0 then
		ffi.copy(self.vertices, vertices, floats * 4)
	end
	if indexCount > 0 then
		ffi.copy(self.indices, indices, indexCount * 4)
	end

	self.stride = stride
	self.vertexCount = vertexCount
	self.indexCount = indexCount
	self.changed = true
end

---@type fun(path: string, what: string): string
local function readFile(path, what)
	local file = io.open(path, "rb")
	if not file then
		error("lupa: cannot open " .. what .. " '" .. path .. "'")
	end

	local data = file:read("*a")
	file:close()

	return data
end

--- safety: a larger image would be rejected, and sampling a clipped one is worse
--- than scaling it, so box-filter it down to a layer
---@type fun(w: number, h: number, pixels: ffi.cdata*, maxW: number, maxH: number): number, number, ffi.cdata*
local function fit(w, h, pixels, maxW, maxH)
	if w <= maxW and h <= maxH then
		return w, h, pixels
	end

	local scale = math.min(maxW / w, maxH / h)
	local nw = math.max(1, math.floor(w * scale))
	local nh = math.max(1, math.floor(h * scale))
	local out = byteArray(nw * nh * 4)

	for y = 0, nh - 1 do
		local sy0 = math.floor(y * h / nh)
		local sy1 = math.max(sy0 + 1, math.floor((y + 1) * h / nh))
		for x = 0, nw - 1 do
			local sx0 = math.floor(x * w / nw)
			local sx1 = math.max(sx0 + 1, math.floor((x + 1) * w / nw))

			local r, g, b, a, n = 0, 0, 0, 0, 0
			for sy = sy0, sy1 - 1 do
				local row = sy * w * 4
				for sx = sx0, sx1 - 1 do
					local p = row + sx * 4
					r = r + pixels[p]
					g = g + pixels[p + 1]
					b = b + pixels[p + 2]
					a = a + pixels[p + 3]
					n = n + 1
				end
			end

			local o = (y * nw + x) * 4
			out[o] = r / n
			out[o + 1] = g / n
			out[o + 2] = b / n
			out[o + 3] = a / n
		end
	end

	return nw, nh, out
end

---@class lupa.Assets
---@field private draw lupa.Draw
---@field private images table<string, lupa.Texture>
---@field private meshes table<string, lupa.Mesh>
local Assets = {}
Assets.__index = Assets

---@type fun(draw: lupa.Draw): lupa.Assets
function Assets.new(draw)
	return setmetatable({
		draw = draw,
		images = {},
		meshes = {},
	}, Assets)
end

---@type fun(self: lupa.Assets, path: string): lupa.Texture
function Assets:image(path)
	local cached = self.images[path]
	if cached then
		return cached
	end

	local width, height, pixels = png.decode(readFile(path, "image"))
	width, height, pixels = fit(width, height, pixels, self.draw.maxTextureWidth, self.draw.maxTextureHeight)

	local texture = Texture.new(self.draw:addTexture(width, height, pixels), width, height)
	self.images[path] = texture

	return texture
end

---@type fun(self: lupa.Assets, vertices: number[], indices: number[]?, stride: number?): lupa.Mesh
function Assets:mesh(vertices, indices, stride)
	return Mesh.new(vertices, indices, stride)
end

---@type fun(self: lupa.Assets, path: string): lupa.Mesh
function Assets:obj(path)
	local cached = self.meshes[path]
	if cached then
		return cached
	end

	local vertices, indices = obj.parse(readFile(path, "mesh"))
	local mesh = Mesh.new(vertices, indices)
	self.meshes[path] = mesh

	return mesh
end

---@type fun(self: lupa.Assets, width: number, height: number, pixels: ffi.cdata*, options: lupa.TextureOptions?): lupa.Texture
function Assets:texture(width, height, pixels, options)
	width, height, pixels = fit(width, height, pixels, self.draw.maxTextureWidth, self.draw.maxTextureHeight)
	return Texture.new(self.draw:addTexture(width, height, pixels, options), width, height, options)
end

return Assets
