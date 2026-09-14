--- Wavefront OBJ parsing, enough for the mesh formats a game actually ships:
--- positions, UVs, normals and faces (triangles or larger polygons, which are
--- fan-triangulated).
---
--- Output is a flat vertex stream in lupa's mesh layout -- x, y, z, nx, ny, nz,
--- u, v -- plus 0-based triangle indices, ready for Draw:createMesh.
local M = {}

---@param corner string e.g. "1/2/3", "1//3", "1/2" or "1"
---@return number? position, number? uv, number? normal
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

--- OBJ indices are 1-based, and negative values count back from the end of the
--- list as it stands at that point in the file.
local function resolve(index, count)
	if not index then
		return nil
	end
	if index < 0 then
		return count + index + 1
	end
	return index
end

---@param text string contents of a .obj file
---@return number[] vertices flat, 8 floats per vertex
---@return number[] indices flat, 0-based triangles
function M.parse(text)
	local positions, texcoords, normals = {}, {}, {}
	-- How many of each had been read at the time a face referenced them, for
	-- resolving relative (negative) indices.
	local positionsSeen = 0
	local texcoordsSeen = 0
	local normalsSeen = 0

	local vertices = {}
	local indices = {}
	local corners = {}   -- "vi/ti/ni" -> output vertex index
	local cornerCount = 0

	---@param vi number
	---@param ti number?
	---@param ni number?
	---@return number outputIndex, number viResolved
	local unique = 0

	local function emitCorner(vi, ti, ni)
		-- Corners carrying a normal can be shared between faces. Those without
		-- one cannot: a flat normal is written per triangle, so a shared vertex
		-- would be overwritten by whichever face came last.
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
		local x = positions[p + 1] or 0
		local y = positions[p + 2] or 0
		local z = positions[p + 3] or 0

		local nx, ny, nz = 0, 0, 0
		if ni then
			local n = (ni - 1) * 3
			nx = normals[n + 1] or 0
			ny = normals[n + 2] or 0
			nz = normals[n + 3] or 0
		end

		local u, v = 0, 0
		if ti then
			local t = (ti - 1) * 2
			u = texcoords[t + 1] or 0
			v = texcoords[t + 2] or 0
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

	for line in text:gmatch("[^\r\n]+") do
		local kind, rest = line:match("^(%S+)%s*(.*)$")

		if kind == "v" then
			local x, y, z = rest:match("^(%S+)%s+(%S+)%s+(%S+)")
			positionsSeen = positionsSeen + 1
			local i = #positions
			positions[i + 1] = tonumber(x) or 0
			positions[i + 2] = tonumber(y) or 0
			positions[i + 3] = tonumber(z) or 0
		elseif kind == "vt" then
			local u, v = rest:match("^(%S+)%s+(%S+)")
			texcoordsSeen = texcoordsSeen + 1
			local i = #texcoords
			texcoords[i + 1] = tonumber(u) or 0
			texcoords[i + 2] = tonumber(v) or 0
		elseif kind == "vn" then
			local x, y, z = rest:match("^(%S+)%s+(%S+)%s+(%S+)")
			normalsSeen = normalsSeen + 1
			local i = #normals
			normals[i + 1] = tonumber(x) or 0
			normals[i + 2] = tonumber(y) or 0
			normals[i + 3] = tonumber(z) or 0
		elseif kind == "f" then
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

			if #face >= 3 then
				-- Fan-triangulate: 0,1,2  0,2,3  0,3,4 ...
				local first, firstVi = emitCorner(face[1][1], face[1][2], face[1][3])
				local prev, prevVi = emitCorner(face[2][1], face[2][2], face[2][3])

				for k = 3, #face do
					local cur, curVi = emitCorner(face[k][1], face[k][2], face[k][3])

					-- If the file carried no normals, give the triangle a flat
					-- one so lighting still works.
					if normalsSeen == 0 then
						local a = (firstVi - 1) * 3
						local b = (prevVi - 1) * 3
						local c = (curVi - 1) * 3
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
							nx, ny, nz = nx / len, ny / len, nz / len
						else
							nx, ny, nz = 0, 0, 1
						end

						for _, idx in ipairs({ first, prev, cur }) do
							local o = idx * 8
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
		end
	end

	return vertices, indices
end

return M
