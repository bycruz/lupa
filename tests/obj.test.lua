--- The Wavefront OBJ loader.
---
--- Meshes come out flat: 8 floats per vertex (position, normal, uv) and 0-based
--- triangle indices, which is what the arenas and the instanced shader expect.
local test = require("lde-test")
local obj = require("lupa.obj")

---@param text string
---@return number[] vertices
---@return number[] indices
local function parse(text)
	return obj.parse(text)
end

test.it("obj: a triangle with positions only", function()
	local vertices, indices = parse([[
v 0 0 0
v 1 0 0
v 0 1 0
f 1 2 3
]])

	test.equal(#vertices / 8, 3)
	test.equal(#indices, 3)

	-- Positions come through in order, with normals and uvs left at zero for the
	-- flat normal pass to fill in.
	test.equal(vertices[1], 0) test.equal(vertices[2], 0) test.equal(vertices[3], 0)
	test.equal(vertices[9], 1) test.equal(vertices[10], 0) test.equal(vertices[11], 0)
	test.equal(vertices[17], 0) test.equal(vertices[18], 1) test.equal(vertices[19], 0)

	test.equal(indices[1], 0) test.equal(indices[2], 1) test.equal(indices[3], 2)
end)

test.it("obj: positions, uvs and normals are paired per corner", function()
	local vertices, indices = parse([[
v 0 0 0
v 1 0 0
v 0 1 0
vt 0 1
vt 1 1
vt 0 0
vn 0 0 1
f 1/1/1 2/2/1 3/3/1
]])

	test.equal(#vertices / 8, 3)
	test.equal(#indices, 3)

	local function vertex(i)
		local o = (i - 1) * 8
		return vertices[o + 1], vertices[o + 2], vertices[o + 3],
			vertices[o + 4], vertices[o + 5], vertices[o + 6],
			vertices[o + 7], vertices[o + 8]
	end

	local x, y, z, nx, ny, nz, u, v = vertex(2)
	test.equal(x, 1) test.equal(y, 0) test.equal(z, 0)
	test.equal(nx, 0) test.equal(ny, 0) test.equal(nz, 1)
	test.equal(u, 1) test.equal(v, 1)
end)

test.it("obj: positions and uvs without normals", function()
	local vertices, indices = parse([[
v 0 0 0
v 1 0 0
v 0 1 0
vt 0 0
vt 1 0
vt 0 1
f 1/1 2/2 3/3
]])

	test.equal(#vertices / 8, 3)
	test.equal(#indices, 3)
	test.equal(vertices[7], 0)
	test.equal(vertices[8], 0)
	test.equal(vertices[15], 1)
	test.equal(vertices[16], 0)
end)

test.it("obj: a quad is fan triangulated", function()
	local vertices, indices = parse([[
v 0 0 0
v 1 0 0
v 1 1 0
v 0 1 0
f 1 2 3 4
]])

	-- One quad becomes two triangles over the same four corners: the fan keeps
	-- the first corner and walks the rest.
	test.equal(#vertices / 8, 4)
	test.equal(#indices, 6)
	test.equal(indices[1], 0) test.equal(indices[2], 1) test.equal(indices[3], 2)
	test.equal(indices[4], 0) test.equal(indices[5], 2) test.equal(indices[6], 3)
end)

test.it("obj: shared corners are kept shared when they carry normals", function()
	local vertices, indices = parse([[
v 0 0 0
v 1 0 0
v 1 1 0
v 0 1 0
vn 0 0 1
f 1//1 2//1 3//1 4//1
]])

	-- Four corners, two triangles, and no duplicated vertices.
	test.equal(#vertices / 8, 4)
	test.equal(#indices, 6)
end)

test.it("obj: a quad without normals stays four corners", function()
	local vertices, indices = parse([[
v 0 0 0
v 1 0 0
v 1 1 0
v 0 1 0
f 1 2 3 4
]])

	-- Fan triangulation reuses the face's first corner, so the quad keeps its four
	-- vertices and gains a second triangle.
	test.equal(#vertices / 8, 4)
	test.equal(#indices, 6)
	test.equal(indices[1], 0) test.equal(indices[2], 1) test.equal(indices[3], 2)
	test.equal(indices[4], 0) test.equal(indices[5], 2) test.equal(indices[6], 3)
end)

test.it("obj: a file without normals gets one per triangle", function()
	local vertices, indices = parse([[
v 0 0 0
v 1 0 0
v 0 1 0
f 1 2 3
]])

	-- The triangle lies in the xy plane wound counter-clockwise, so its normal is
	-- +Z for every corner.
	for corner = 1, 3 do
		local o = (indices[corner]) * 8
		test.equal(vertices[o + 4], 0)
		test.equal(vertices[o + 5], 0)
		test.equal(vertices[o + 6], 1)
	end
end)

test.it("obj: negative indices count back from the end", function()
	local vertices, indices = parse([[
v 0 0 0
v 1 0 0
v 0 1 0
f -3 -2 -1
]])

	test.equal(#vertices / 8, 3)
	test.equal(#indices, 3)
	test.equal(vertices[1], 0) test.equal(vertices[2], 0)
	test.equal(vertices[9], 1) test.equal(vertices[10], 0)
	test.equal(vertices[17], 0) test.equal(vertices[18], 1)
end)

test.it("obj: a face only sees what was declared before it", function()
	-- Negative indices resolve against how much of each list had been read at
	-- that point in the file, not against the final count.
	local vertices, indices = parse([[
v 0 0 0
v 1 0 0
v 0 1 0
f -3 -2 -1
v 5 5 5
]])

	test.equal(#indices, 3)
	test.equal(vertices[9], 1)
	test.equal(vertices[10], 0)
end)

test.it("obj: a file with no faces produces no geometry", function()
	local vertices, indices = parse([[
v 1.5 -2.25 3
vn 0 1 0
]])

	test.equal(#vertices, 0)
	test.equal(#indices, 0)
end)
