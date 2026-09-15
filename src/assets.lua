local ffi = require("ffi")

local obj = require("lupa.obj")
local png = require("lupa.png")

---@type ffi.ctype* float[?]
local floatArray = ffi.typeof("float[?]")

---@type ffi.ctype* int[?]
local intArray = ffi.typeof("int[?]")

---@type ffi.ctype* uint8_t[?]
local byteArray = ffi.typeof("uint8_t[?]")

--- Shared by every mesh built without indices, which draw in vertex order.
---@type ffi.cdata*
local noIndices = ffi.new("int[0]")

---@class lupa.Texture
---@field layer number index into the texture array, as used by the shader
---@field width number
---@field height number
local Texture = {}
Texture.__index = Texture

---@type fun(layer: number, width: number, height: number): lupa.Texture
function Texture.new(layer, width, height)
	return setmetatable({ layer = layer, width = width, height = height }, Texture)
end

---@class lupa.Mesh
---@field vertices ffi.cdata* flat, 8 floats per vertex: x, y, z, nx, ny, nz, u, v
---@field indices ffi.cdata* flat, 0-based triangle indices
---@field vertexCount number
---@field indexCount number
local Mesh = {}
Mesh.__index = Mesh

---@type fun(vertices: number[], indices: number[]?): lupa.Mesh
function Mesh.new(vertices, indices)
	if #vertices % 8 ~= 0 then
		error("lupa: mesh vertices must be 8 floats each (x, y, z, nx, ny, nz, u, v); got " .. #vertices)
	end

	return setmetatable({
		vertices = floatArray(#vertices, vertices),
		indices = indices and intArray(#indices, indices) or noIndices,
		vertexCount = #vertices / 8,
		indexCount = indices and #indices or 0,
	}, Mesh)
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

--- Load a PNG into the texture array, cached by path.
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

--- Build a mesh from flat vertex and index arrays: 8 floats per vertex and
--- 0-based triangles, which may be omitted to draw the vertices in order.
---@type fun(self: lupa.Assets, vertices: number[], indices: number[]?): lupa.Mesh
function Assets:mesh(vertices, indices)
	return Mesh.new(vertices, indices)
end

--- Load a Wavefront .obj into a mesh, cached by path.
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

--- Build a texture from raw RGBA8 pixels you supply yourself.
---@type fun(self: lupa.Assets, width: number, height: number, pixels: ffi.cdata*): lupa.Texture
function Assets:texture(width, height, pixels)
	width, height, pixels = fit(width, height, pixels, self.draw.maxTextureWidth, self.draw.maxTextureHeight)
	return Texture.new(self.draw:addTexture(width, height, pixels), width, height)
end

return Assets
