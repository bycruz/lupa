--- Loading user assets. Currently images (PNG) go into lupa's texture array.
local ffi = require("ffi")
local png = require("lupa.png")
local obj = require("lupa.obj")

---@class lupa.Texture
---@field layer number index into the texture array, as used by the shader
---@field width number
---@field height number
---@field path string? where it came from, for debugging
local Texture = {}
Texture.__index = Texture

function Texture.new(layer, width, height, path)
	return setmetatable({
		layer = layer,
		width = width,
		height = height,
		path = path,
	}, Texture)
end

---@class lupa.Mesh
---@field vertices ffi.cdata* flat, 8 floats per vertex: x, y, z, nx, ny, nz, u, v
---@field indices ffi.cdata* flat, 0-based triangle indices into this mesh
---@field vertexCount number
---@field indexCount number
local Mesh = {}
Mesh.__index = Mesh

--- Build a mesh from flat Lua arrays. Vertices are 8 floats each: position,
--- normal, then UV. Indices are 0-based triangles and may be omitted, in which
--- case the vertices are drawn in order.
---
--- Meshes are immutable once built, so a scene can hold one and draw it as many
--- times as it likes.
---@param vertices number[]|ffi.cdata*
---@param indices number[]|ffi.cdata*|nil
---@param vertexCount number? required when passing an ffi array
---@param indexCount number? required when passing an ffi array
---@return lupa.Mesh
function Mesh.new(vertices, indices, vertexCount, indexCount)
	local v, i

	if type(vertices) == "table" then
		if #vertices % 8 ~= 0 then
			error("lupa: mesh vertices must be 8 floats each (x,y,z, nx,ny,nz, u,v); got "
				.. #vertices)
		end
		v = ffi.new("float[?]", #vertices, vertices)
		vertexCount = #vertices / 8
	else
		v = vertices
		if not vertexCount then
			error("lupa: pass vertexCount when building a mesh from an ffi array")
		end
	end

	if indices == nil then
		i = ffi.new("int[0]")
		indexCount = 0
	elseif type(indices) == "table" then
		i = ffi.new("int[?]", #indices, indices)
		indexCount = #indices
	else
		i = indices
		if not indexCount then
			error("lupa: pass indexCount when building a mesh from an ffi array")
		end
	end

	return setmetatable({
		vertices = v,
		indices = i,
		vertexCount = vertexCount,
		indexCount = indexCount,
	}, Mesh)
end

---@class lupa.Assets
---@field private draw lupa.Draw
local Assets = {}
Assets.__index = Assets

---@param draw lupa.Draw
function Assets.new(draw)
	return setmetatable({
		draw = draw,
		images = {},
		meshes = {},
	}, Assets)
end

--- Box-filter down to fit the texture array's layer size. A texture larger than
--- a layer would otherwise be rejected, and silently sampling a clipped image
--- is worse than scaling it.
local function fit(w, h, pixels, maxW, maxH)
	if w <= maxW and h <= maxH then
		return w, h, pixels
	end

	local scale = math.min(maxW / w, maxH / h)
	local nw = math.max(1, math.floor(w * scale))
	local nh = math.max(1, math.floor(h * scale))
	local out = ffi.new("uint8_t[?]", nw * nh * 4)

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

--- Load a PNG into the texture array. Results are cached by path.
---@param path string
---@return lupa.Texture
function Assets:image(path)
	local cached = self.images[path]
	if cached then
		return cached
	end

	local file = io.open(path, "rb")
	if not file then
		error("lupa: cannot open image '" .. path .. "'")
	end
	local data = file:read("*a")
	file:close()

	local w, h, pixels = png.decode(data)
	w, h, pixels = fit(w, h, pixels, self.draw.maxTextureWidth, self.draw.maxTextureHeight)

	local layer = self.draw:addTexture(w, h, pixels)
	local texture = Texture.new(layer, w, h, path)
	self.images[path] = texture
	return texture
end

--- Build a mesh from flat vertex and index arrays. Vertices are 8 floats each
--- -- x, y, z, nx, ny, nz, u, v -- and indices are 0-based triangles.
---@param vertices number[]|ffi.cdata*
---@param indices number[]|ffi.cdata*|nil
---@return lupa.Mesh
function Assets:mesh(vertices, indices)
	return Mesh.new(vertices, indices)
end

--- Load a Wavefront .obj into a mesh. Results are cached by path.
---@param path string
---@return lupa.Mesh
function Assets:obj(path)
	local cached = self.meshes[path]
	if cached then
		return cached
	end

	local file = io.open(path, "rb")
	if not file then
		error("lupa: cannot open mesh '" .. path .. "'")
	end
	local text = file:read("*a")
	file:close()

	local vertices, indices = obj.parse(text)
	local mesh = Mesh.new(vertices, indices)
	mesh.path = path
	self.meshes[path] = mesh
	return mesh
end

--- Build a texture from raw RGBA8 bytes you supply yourself.
---@param width number
---@param height number
---@param pixels ffi.cdata* width * height * 4 bytes
---@return lupa.Texture
function Assets:texture(width, height, pixels)
	width, height, pixels = fit(width, height, pixels,
		self.draw.maxTextureWidth, self.draw.maxTextureHeight)
	local layer = self.draw:addTexture(width, height, pixels)
	return Texture.new(layer, width, height)
end

return Assets
