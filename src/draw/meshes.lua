local ffi = require("ffi")

local CUBE_VERTICES = ffi.new("float[192]", {
	-0.5, -0.5,  0.5,  0,  0,  1,  0, 1,
	 0.5, -0.5,  0.5,  0,  0,  1,  1, 1,
	 0.5,  0.5,  0.5,  0,  0,  1,  1, 0,
	-0.5,  0.5,  0.5,  0,  0,  1,  0, 0,
	 0.5, -0.5, -0.5,  0,  0, -1,  0, 1,
	-0.5, -0.5, -0.5,  0,  0, -1,  1, 1,
	-0.5,  0.5, -0.5,  0,  0, -1,  1, 0,
	 0.5,  0.5, -0.5,  0,  0, -1,  0, 0,
	 0.5, -0.5,  0.5,  1,  0,  0,  0, 1,
	 0.5, -0.5, -0.5,  1,  0,  0,  1, 1,
	 0.5,  0.5, -0.5,  1,  0,  0,  1, 0,
	 0.5,  0.5,  0.5,  1,  0,  0,  0, 0,
	-0.5, -0.5, -0.5, -1,  0,  0,  0, 1,
	-0.5, -0.5,  0.5, -1,  0,  0,  1, 1,
	-0.5,  0.5,  0.5, -1,  0,  0,  1, 0,
	-0.5,  0.5, -0.5, -1,  0,  0,  0, 0,
	-0.5,  0.5,  0.5,  0,  1,  0,  0, 1,
	 0.5,  0.5,  0.5,  0,  1,  0,  1, 1,
	 0.5,  0.5, -0.5,  0,  1,  0,  1, 0,
	-0.5,  0.5, -0.5,  0,  1,  0,  0, 0,
	-0.5, -0.5, -0.5,  0, -1,  0,  0, 1,
	 0.5, -0.5, -0.5,  0, -1,  0,  1, 1,
	 0.5, -0.5,  0.5,  0, -1,  0,  1, 0,
	-0.5, -0.5,  0.5,  0, -1,  0,  0, 0,
})

local CUBE_INDICES = ffi.new("int[36]", {
	 0,  1,  2,  0,  2,  3,
	 4,  5,  6,  4,  6,  7,
	 8,  9, 10,  8, 10, 11,
	12, 13, 14, 12, 14, 15,
	16, 17, 18, 16, 18, 19,
	20, 21, 22, 20, 22, 23,
})

local PLANE_VERTICES = ffi.new("float[32]", {
	-0.5, 0,  0.5,  0, 1, 0,  0, 1,
	 0.5, 0,  0.5,  0, 1, 0,  1, 1,
	 0.5, 0, -0.5,  0, 1, 0,  1, 0,
	-0.5, 0, -0.5,  0, 1, 0,  0, 0,
})

local PLANE_INDICES = ffi.new("int[6]", { 0, 1, 2, 0, 2, 3 })

-- safety: v = 0 is the quad's top edge, so an image drawn in a rect is not flipped
local RECT_VERTICES = ffi.new("float[32]", {
	-0.5, -0.5, 0,  0, 0, 1,  0, 1,
	 0.5, -0.5, 0,  0, 0, 1,  1, 1,
	-0.5,  0.5, 0,  0, 0, 1,  0, 0,
	 0.5,  0.5, 0,  0, 0, 1,  1, 0,
})

local RECT_INDICES = ffi.new("int[6]", { 0, 1, 2, 1, 3, 2 })

---@type fun(vertices: ffi.cdata*, indices: ffi.cdata*, vertexCount: number, indexCount: number): lupa.Mesh
local function meshOf(vertices, indices, vertexCount, indexCount)
	local mesh = {
		vertices = vertices,
		indices = indices,
		stride = 8,
		vertexCount = vertexCount,
		indexCount = indexCount,
	}
	---@cast mesh lupa.Mesh
	return mesh
end

---@type table<number, lupa.Mesh>
local sphereCache = {}

---@type fun(segments: number): lupa.Mesh
local function sphere(segments)
	local hit = sphereCache[segments]
	if hit then
		return hit
	end

	local rings = math.max(2, math.floor(segments / 2))
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
			-- safety: the normal is the position doubled, which is only unit because the
			-- sphere is built with a radius of 0.5
			verts[v + 3] = x * 2
			verts[v + 4] = y * 2
			verts[v + 5] = z * 2
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

	local mesh = meshOf(verts, indices, vcount, icount)
	sphereCache[segments] = mesh

	return mesh
end

return {
	rect = meshOf(RECT_VERTICES, RECT_INDICES, 4, 6),
	cube = meshOf(CUBE_VERTICES, CUBE_INDICES, 24, 36),
	plane = meshOf(PLANE_VERTICES, PLANE_INDICES, 4, 6),
	sphere = sphere,
}
