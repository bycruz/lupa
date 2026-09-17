local M = {}

---@type fun(corner: string): number?, number?, number?
local function parseCorner(corner)
	local vi, ti, ni = corner:match("^(%-?%d+)/(%-?%d*)/(%-?%d*)$")
	if vi then
		return tonumber(vi), tonumber(ti), tonumber(ni)
	end

	local v2, t2 = corner:match("^(%-?%d+)/(%-?%d*)$")
	if v2 then
		return tonumber(v2), tonumber(t2), nil
	end

	local v3 = corner:match("^(%-?%d+)$")
	if v3 then
		return tonumber(v3), nil, nil
	end

	return nil
end

-- safety: OBJ indices are 1-based, and a negative one counts back from the list so far
---@type fun(index: number?, count: number): number?
local function resolve(index, count)
	if not index then
		return nil
	end
	if index < 0 then
		return count + index + 1
	end
	return index
end

---@type fun(text: string): number[], number[]
function M.parse(text)
	local positions, texcoords, normals = {}, {}, {}
	local positionsSeen, texcoordsSeen, normalsSeen = 0, 0, 0

	local vertices, indices = {}, {}
	local corners = {}
	local cornerCount, unique = 0, 0

---@type fun(vi: number, ti: number?, ni: number?): number, number
	local function emitCorner(vi, ti, ni)
		-- safety: a corner without a normal cannot be shared, because the flat normal
		-- pass would overwrite it from whichever face came last
		local key
		if ni then
			key = vi .. "/" .. tostring(ti) .. "/" .. ni
		else
			unique = unique + 1
			key = "u" .. unique
		end

		local existing = corners[key]
		if existing then
			return existing, vi
		end

		local p = (vi - 1) * 3
		local x, y, z = positions[p + 1] or 0, positions[p + 2] or 0, positions[p + 3] or 0

		local nx, ny, nz = 0, 0, 0
		if ni then
			local n = (ni - 1) * 3
			nx, ny, nz = normals[n + 1] or 0, normals[n + 2] or 0, normals[n + 3] or 0
		end

		local u, v = 0, 0
		if ti then
			local t = (ti - 1) * 2
			u, v = texcoords[t + 1] or 0, texcoords[t + 2] or 0
		end

		local i = #vertices
		vertices[i + 1] = x
		vertices[i + 2] = y
		vertices[i + 3] = z
		vertices[i + 4] = nx
		vertices[i + 5] = ny
		vertices[i + 6] = nz
		vertices[i + 7] = u
		vertices[i + 8] = v

		local out = cornerCount
		cornerCount = cornerCount + 1
		corners[key] = out

		return out, vi
	end

---@type fun(rest: string)
	local function readPositions(rest)
		local x, y, z = rest:match("^(%S+)%s+(%S+)%s+(%S+)")
		local i = #positions
		positions[i + 1] = tonumber(x) or 0
		positions[i + 2] = tonumber(y) or 0
		positions[i + 3] = tonumber(z) or 0
		positionsSeen = positionsSeen + 1
	end

---@type fun(rest: string)
	local function readTexcoords(rest)
		local u, v = rest:match("^(%S+)%s+(%S+)")
		local i = #texcoords
		texcoords[i + 1] = tonumber(u) or 0
		texcoords[i + 2] = tonumber(v) or 0
		texcoordsSeen = texcoordsSeen + 1
	end

---@type fun(rest: string)
	local function readNormals(rest)
		local x, y, z = rest:match("^(%S+)%s+(%S+)%s+(%S+)")
		local i = #normals
		normals[i + 1] = tonumber(x) or 0
		normals[i + 2] = tonumber(y) or 0
		normals[i + 3] = tonumber(z) or 0
		normalsSeen = normalsSeen + 1
	end

---@type fun(a: number, b: number, c: number): number, number, number
	local function flatNormal(a, b, c)
		local e1x, e1y, e1z = positions[b + 1] - positions[a + 1],
			positions[b + 2] - positions[a + 2],
			positions[b + 3] - positions[a + 3]
		local e2x, e2y, e2z = positions[c + 1] - positions[a + 1],
			positions[c + 2] - positions[a + 2],
			positions[c + 3] - positions[a + 3]
		local nx = e1y * e2z - e1z * e2y
		local ny = e1z * e2x - e1x * e2z
		local nz = e1x * e2y - e1y * e2x
		local len = math.sqrt(nx * nx + ny * ny + nz * nz)

		if len > 0 then
			return nx / len, ny / len, nz / len
		end
		return 0, 0, 1
	end

---@type fun(rest: string)
	local function readFace(rest)
		local face = {}
		for corner in rest:gmatch("%S+") do
			local vi, ti, ni = parseCorner(corner)
			if vi then
				face[#face + 1] = {
					resolve(vi, positionsSeen),
					resolve(ti, texcoordsSeen),
					resolve(ni, normalsSeen),
				}
			end
		end

		if #face < 3 then
			return
		end

		local first, firstVi = emitCorner(face[1][1], face[1][2], face[1][3])
		local prev, prevVi = emitCorner(face[2][1], face[2][2], face[2][3])

		for k = 3, #face do
			local cur, curVi = emitCorner(face[k][1], face[k][2], face[k][3])

			if normalsSeen == 0 then
				local nx, ny, nz = flatNormal((firstVi - 1) * 3, (prevVi - 1) * 3, (curVi - 1) * 3)
				for _, at in ipairs({ first, prev, cur }) do
					local o = at * 8
					vertices[o + 4] = nx
					vertices[o + 5] = ny
					vertices[o + 6] = nz
				end
			end

			indices[#indices + 1] = first
			indices[#indices + 1] = prev
			indices[#indices + 1] = cur
			prev, prevVi = cur, curVi
		end
	end

	for line in text:gmatch("[^\r\n]+") do
		local kind, rest = line:match("^(%S+)%s*(.*)$")

		if kind == "v" then
			readPositions(rest)
		elseif kind == "vt" then
			readTexcoords(rest)
		elseif kind == "vn" then
			readNormals(rest)
		elseif kind == "f" then
			readFace(rest)
		end
	end

	return vertices, indices
end

return M
