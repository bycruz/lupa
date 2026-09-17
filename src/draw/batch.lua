local ffi = require("ffi")

local limits = require("lupa.draw.limits")
local meshes = require("lupa.draw.meshes")
local records = require("lupa.draw.records")

-- safety: a vertex is 9 floats in and 16 bytes stored: a position in 16 bits of the
-- mesh's own size, the normal as three signed normalized bytes, and a uv in 16 bits of
-- the mesh's own range, with the two scales riding in the instance that draws it
local PACKED_VERTEX_BYTES = 16
local SOURCE_VERTEX_FLOATS = 8
local INDEX_BYTES = 4

--- The largest a stored coordinate can be, so what one of them is worth is the extent
--- of the mesh over this.
local COORDINATE_LIMIT = 32767

-- safety: the byte a vertex without a tile carries, which tells the shader to sample the
-- texture the draw has set instead of one the vertex names
local NO_TILE = 255

local LAST_TILE = 126

---@type ffi.ctype* float pointer, cached because ffi.cast and ffi.new would
--- otherwise parse the type string on every call
local floatPointer = ffi.typeof("float*")

---@type ffi.ctype* unsigned byte pointer
local bytePointer = ffi.typeof("uint8_t*")

---@type ffi.ctype* uint8_t[?]
local byteArray = ffi.typeof("uint8_t[?]")

---@type ffi.ctype* int16_t pointer
local shortPointer = ffi.typeof("int16_t*")

---@type fun(value: number): number
local function snormByte(value)
	local scaled = math.floor(value * 127 + 0.5)
	if scaled < -127 then
		scaled = -127
	elseif scaled > 127 then
		scaled = 127
	end
	-- safety: -1 is 0x80, so the byte is returned as its unsigned value
	return scaled < 0 and scaled + 256 or scaled
end

---@type fun(value: number): number
local function colorByte(value)
	-- safety: rounded rather than truncated, so 0.2 and 0.6 come back as themselves
	local byte = math.floor(value * 255 + 0.5)
	if byte < 0 then
		return 0
	elseif byte > 255 then
		return 255
	end
	return byte
end

--- What a mesh's positions and uvs are worth when they are stored as 16 bit integers:
--- the extent of the mesh, so a car and a chunk both keep their detail.
---@type fun(mesh: lupa.Mesh): number, number
local function meshScales(mesh)
	local source = ffi.cast(floatPointer, mesh.vertices)
	local stride = mesh.stride
	local largest, largestUv = 0, 0

	for i = 0, mesh.vertexCount - 1 do
		local src = i * stride
		for axis = 0, 2 do
			local value = source[src + axis]
			value = value < 0 and -value or value
			if value > largest then
				largest = value
			end
		end

		for axis = 6, 7 do
			local value = source[src + axis]
			value = value < 0 and -value or value
			if value > largestUv then
				largestUv = value
			end
		end
	end

	-- safety: an empty mesh and a mesh of one point both divide by nothing, so the
	-- smallest scale that can hold anything is used instead
	return math.max(largest, 1e-6) / COORDINATE_LIMIT, math.max(largestUv, 1e-6) / COORDINATE_LIMIT
end

---@type fun(value: number, scale: number): number
local function fixed(value, scale)
	local scaled = math.floor(value / scale + 0.5)
	if scaled > COORDINATE_LIMIT then
		return COORDINATE_LIMIT
	elseif scaled < -COORDINATE_LIMIT then
		return -COORDINATE_LIMIT
	end
	return scaled
end

---@type fun(mesh: lupa.Mesh, scratch: ffi.cdata*)
local function packVertices(mesh, scratch)
	local source = ffi.cast(floatPointer, mesh.vertices)
	local shorts = ffi.cast(shortPointer, scratch)
	local bytes = ffi.cast(bytePointer, scratch)
	local stride = mesh.stride
	local positionScale, uvScale = meshScales(mesh)

	mesh.positionScale, mesh.uvScale = positionScale, uvScale

	for i = 0, mesh.vertexCount - 1 do
		local src = i * stride
		local dst = i * PACKED_VERTEX_BYTES / 2
		local normal = i * PACKED_VERTEX_BYTES + 6

		shorts[dst] = fixed(source[src], positionScale)
		shorts[dst + 1] = fixed(source[src + 1], positionScale)
		shorts[dst + 2] = fixed(source[src + 2], positionScale)
		bytes[normal] = snormByte(source[src + 3])
		bytes[normal + 1] = snormByte(source[src + 4])
		bytes[normal + 2] = snormByte(source[src + 5])
		shorts[dst + 5] = fixed(source[src + 6], uvScale)
		shorts[dst + 6] = fixed(source[src + 7], uvScale)

		local tile = stride > SOURCE_VERTEX_FLOATS and source[src + 8] or -1
		if tile < 0 then
			bytes[normal + 3] = NO_TILE
		else
			-- safety: the byte is signed normalized, so a tile past 126 would come back negative
			bytes[normal + 3] = tile > LAST_TILE and LAST_TILE or tile
		end
	end
end

---@param array ffi.cdata*
---@param capacity number current element count
---@param needed number required element count
---@param elementSize number bytes per element
---@param elementType ffi.ctype*
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

---@type fun(arena: table, vertexCount: number): ffi.cdata*
local function scratchFor(arena, vertexCount)
	local needed = vertexCount * PACKED_VERTEX_BYTES
	if needed > arena.scratchBytes then
		arena.scratchBytes = math.max(needed, PACKED_VERTEX_BYTES * 256)
		arena.scratch = byteArray(arena.scratchBytes)
	end
	return arena.scratch
end

---@class lupa.draw.Placement
---@field vertexBase number first vertex of the mesh, for vertexOffset
---@field indexBase number first index of the mesh, for firstIndex
---@field vertexOffset number bytes into the vertex arena
---@field indexOffset number bytes into the index arena
---@field vertexBytes number bytes reserved for the mesh
---@field indexBytes number bytes reserved for the mesh

---@class lupa.draw.Span
---@field offset number
---@field bytes number

---@class lupa.draw.Arena
---@field vertexBuffer hood.Buffer
---@field indexBuffer hood.Buffer
---@field vertexCapacity number bytes
---@field indexCapacity number bytes
---@field vertexUsed number bytes, the high water mark
---@field indexUsed number bytes, the high water mark
---@field freeVertices lupa.draw.Span[] released runs, in offset order
---@field freeIndices lupa.draw.Span[]
---@field placements table<lupa.Mesh, lupa.draw.Placement>
---@field scratch ffi.cdata*|false
---@field scratchBytes number

---@class lupa.draw.Batch
---@field newArena fun(device: hood.Device): lupa.draw.Arena
---@field placeMesh fun(draw: lupa.Draw, mesh: lupa.Mesh): number vertexBase, number indexBase
---@field releaseMesh fun(draw: lupa.Draw, mesh: lupa.Mesh)
---@field append fun(draw: lupa.Draw, mesh: lupa.Mesh): lupa.draw.Instance
---@field emit fun(draw: lupa.Draw, mesh: lupa.Mesh, px: number, py: number, pz: number, sx: number, sy: number, sz: number)
---@field emitRect fun(draw: lupa.Draw, x: number, y: number, w: number, h: number)
---@field reset fun(draw: lupa.Draw)
---@field breakBatch fun(draw: lupa.Draw)
local batch = {}

---@type fun(device: hood.Device): lupa.draw.Arena
function batch.newArena(device)
	return {
		vertexBuffer = device:createBuffer({
			size = limits.arenaVertices,
			usages = { "VERTEX", "COPY_DST" },
		}),
		indexBuffer = device:createBuffer({
			size = limits.arenaIndices,
			usages = { "INDEX", "COPY_DST" },
		}),
		vertexCapacity = limits.arenaVertices,
		indexCapacity = limits.arenaIndices,
		vertexUsed = 0,
		indexUsed = 0,
		freeVertices = {},
		freeIndices = {},
		-- safety: placement belongs to the arena, because a mesh is shared by every draw
		placements = setmetatable({}, { __mode = "k" }),
		scratch = false,
		scratchBytes = 0,
	}
end

local MESH_HEADROOM = 1.25

-- safety: anything queued for the old buffers has to land before they go, and a placed
-- mesh keeps its offset, so growth only re-uploads
---@type fun(draw: lupa.Draw, vertexCapacity: number, indexCapacity: number)
local function growArena(draw, vertexCapacity, indexCapacity)
	local arena, device = draw.arena, draw.device

	vertexCapacity = math.max(arena.vertexCapacity, vertexCapacity)
	indexCapacity = math.max(arena.indexCapacity, indexCapacity)
	if vertexCapacity == arena.vertexCapacity and indexCapacity == arena.indexCapacity then
		return
	end

	draw.uploads:flush()
	device.queue:waitIdle()

	local oldVertex, oldIndex = arena.vertexBuffer, arena.indexBuffer
	arena.vertexCapacity, arena.indexCapacity = vertexCapacity, indexCapacity
	arena.vertexBuffer = device:createBuffer({
		size = vertexCapacity,
		usages = { "VERTEX", "COPY_DST" },
	})
	arena.indexBuffer = device:createBuffer({
		size = indexCapacity,
		usages = { "INDEX", "COPY_DST" },
	})

	-- safety: the old buffers go once the new ones hold a copy of every mesh
	for other, at in pairs(arena.placements) do
		local scratch = scratchFor(arena, other.vertexCount)
		packVertices(other, scratch)
		draw.uploads:write(arena.vertexBuffer, other.vertexCount * PACKED_VERTEX_BYTES, scratch, at.vertexOffset)
		draw.uploads:write(arena.indexBuffer, other.indexCount * INDEX_BYTES, other.indices, at.indexOffset)
	end

	draw.uploads:flush()
	oldVertex:destroy()
	oldIndex:destroy()
end

---@type fun(draw: lupa.Draw, vertexBytes: number, indexBytes: number)
local function reserveArena(draw, vertexBytes, indexBytes)
	local arena = draw.arena
	local needVertex = arena.vertexUsed + vertexBytes
	local needIndex = arena.indexUsed + indexBytes
	if needVertex <= arena.vertexCapacity and needIndex <= arena.indexCapacity then
		return
	end

	local vertexCapacity, indexCapacity = arena.vertexCapacity, arena.indexCapacity
	while vertexCapacity < needVertex do
		vertexCapacity = vertexCapacity * 2
	end
	while indexCapacity < needIndex do
		indexCapacity = indexCapacity * 2
	end

	growArena(draw, vertexCapacity, indexCapacity)
end

---@type fun(draw: lupa.Draw, vertexBytes: number, indexBytes: number)
function batch.reserveSpace(draw, vertexBytes, indexBytes)
	growArena(draw, vertexBytes, indexBytes)
end

---@type fun(draw: lupa.Draw, mesh: lupa.Mesh, placement: lupa.draw.Placement)
local function uploadMesh(draw, mesh, placement)
	local arena = draw.arena
	local packed = scratchFor(arena, mesh.vertexCount)
	packVertices(mesh, packed)
	draw.uploads:write(arena.vertexBuffer, mesh.vertexCount * PACKED_VERTEX_BYTES, packed, placement.vertexOffset)
	draw.uploads:write(arena.indexBuffer, mesh.indexCount * INDEX_BYTES, mesh.indices, placement.indexOffset)
end

---@type fun(free: lupa.draw.Span[], bytes: number): number? offset
local function claim(free, bytes)
	if bytes == 0 then
		return nil
	end

	for index = 1, #free do
		local span = free[index]
		if span.bytes >= bytes then
			local offset = span.offset
			if span.bytes == bytes then
				table.remove(free, index)
			else
				span.offset, span.bytes = offset + bytes, span.bytes - bytes
			end
			return offset
		end
	end

	return nil
end

---@type fun(free: lupa.draw.Span[], offset: number, bytes: number)
local function release(free, offset, bytes)
	if bytes == 0 then
		return
	end

	local span = { offset = offset, bytes = bytes }
	local index = 1

	while index <= #free do
		local other = free[index]
		local before = other.offset + other.bytes == span.offset
		local after = span.offset + span.bytes == other.offset

		if before or after then
			span.offset = math.min(span.offset, other.offset)
			span.bytes = span.bytes + other.bytes
			table.remove(free, index)
			-- safety: a joined run can reach the one before it, so the scan starts over
			index = 1
		else
			index = index + 1
		end
	end

	free[#free + 1] = span
end

---@type fun(draw: lupa.Draw, mesh: lupa.Mesh): lupa.draw.Placement
local function reservePlacement(draw, mesh)
	local arena = draw.arena
	-- safety: rounded to whole vertices and indices, or the placement after this
	-- one would start part way into an element
	local vertexBytes = math.ceil(mesh.vertexCount * MESH_HEADROOM) * PACKED_VERTEX_BYTES
	local indexBytes = math.ceil(mesh.indexCount * MESH_HEADROOM) * INDEX_BYTES

	local vertexOffset = claim(arena.freeVertices, vertexBytes)
	local indexOffset = claim(arena.freeIndices, indexBytes)

	if not vertexOffset or not indexOffset then
		-- safety: both arenas or neither, so a mesh never starts inside a released
		-- run and ends past the end of the arena
		if vertexOffset then
			release(arena.freeVertices, vertexOffset, vertexBytes)
		end
		if indexOffset then
			release(arena.freeIndices, indexOffset, indexBytes)
		end

		reserveArena(draw, vertexBytes, indexBytes)
		vertexOffset, indexOffset = arena.vertexUsed, arena.indexUsed
		arena.vertexUsed = arena.vertexUsed + vertexBytes
		arena.indexUsed = arena.indexUsed + indexBytes
	end

	local placement = {
		vertexBase = vertexOffset / PACKED_VERTEX_BYTES,
		indexBase = indexOffset / INDEX_BYTES,
		vertexOffset = vertexOffset,
		indexOffset = indexOffset,
		vertexBytes = vertexBytes,
		indexBytes = indexBytes,
	}

	uploadMesh(draw, mesh, placement)

	return placement
end

---@type fun(draw: lupa.Draw, mesh: lupa.Mesh): number, number
function batch.placeMesh(draw, mesh)
	local arena = draw.arena
	local placement = arena.placements[mesh]

	if not placement then
		placement = reservePlacement(draw, mesh)
		arena.placements[mesh] = placement
		mesh.changed = false
		return placement.vertexBase, placement.indexBase
	end

	if mesh.changed then
		mesh.changed = false
		-- safety: a placement that no longer fits is left behind rather than moved,
		-- because the meshes after it would have to move with it
		if mesh.vertexCount * PACKED_VERTEX_BYTES > placement.vertexBytes
			or mesh.indexCount * INDEX_BYTES > placement.indexBytes
		then
			placement = reservePlacement(draw, mesh)
			arena.placements[mesh] = placement
		else
			uploadMesh(draw, mesh, placement)
		end
	end

	return placement.vertexBase, placement.indexBase
end

---@type fun(draw: lupa.Draw, mesh: lupa.Mesh)
function batch.releaseMesh(draw, mesh)
	local arena = draw.arena
	local placement = arena.placements[mesh]
	if not placement then
		return
	end

	arena.placements[mesh] = nil
	release(arena.freeVertices, placement.vertexOffset, placement.vertexBytes)
	release(arena.freeIndices, placement.indexOffset, placement.indexBytes)
end

---@type fun(draw: lupa.Draw, count: number)
local function reserveInstances(draw, count)
	if draw.instanceCount + count <= draw.instanceCapacity then
		return
	end

	draw.instances, draw.instanceCapacity = growArray(draw.instances, draw.instanceCapacity,
		draw.instanceCount + count, records.instanceStride, records.newInstances)
end

---@type fun(draw: lupa.Draw, count: number)
local function reserveDraws(draw, count)
	if draw.drawRecordCount + count <= draw.drawRecordCapacity then
		return
	end

	draw.drawRecords, draw.drawRecordCapacity = growArray(draw.drawRecords, draw.drawRecordCapacity,
		draw.drawRecordCount + count, records.drawStride, records.newDraws)
end

---@type fun(draw: lupa.Draw, mesh: lupa.Mesh): lupa.draw.Instance
function batch.append(draw, mesh)
	reserveInstances(draw, 1)

	local instance = draw.instances[draw.instanceCount]
	instance.r = colorByte(draw.curR)
	instance.g = colorByte(draw.curG)
	instance.b = colorByte(draw.curB)
	instance.a = colorByte(draw.curA)
	instance.textureIndex = draw.curTexture
	instance.uvU0, instance.uvV0 = draw.texU0, draw.texV0
	instance.uvSpanU, instance.uvSpanV = draw.texU1 - draw.texU0, draw.texV1 - draw.texV0

	local vertexBase, indexBase = batch.placeMesh(draw, mesh)

	-- safety: a mesh's vertices are stored as integers of its own size, so the scale it
	-- was packed with has to travel with every instance that draws it
	instance.positionScale, instance.uvScale = mesh.positionScale or 1, mesh.uvScale or 1
	local count = draw.drawRecordCount

	-- safety: records follow the instance order, so the previous record always
	-- covers the instances directly before this one
	if count > 0 and draw.lastRecordMesh == mesh and draw.lastRecordTexture == draw.curTexture then
		draw.drawRecords[count - 1].instanceCount = draw.drawRecords[count - 1].instanceCount + 1
	else
		reserveDraws(draw, 1)

		local record = draw.drawRecords[count]
		record.indexCount = mesh.indexCount
		record.instanceCount = 1
		record.firstIndex = indexBase
		record.vertexOffset = vertexBase
		record.firstInstance = draw.instanceCount

		draw.drawRecordCount = count + 1
		draw.lastRecordMesh = mesh
		draw.lastRecordTexture = draw.curTexture
	end

	draw.instanceCount = draw.instanceCount + 1

	return instance
end

---@type fun(draw: lupa.Draw, mesh: lupa.Mesh, px: number, py: number, pz: number, sx: number, sy: number, sz: number)
function batch.emit(draw, mesh, px, py, pz, sx, sy, sz)
	if mesh.vertexCount == 0 or mesh.indexCount == 0 then
		return
	end

	local instance = batch.append(draw, mesh)
	local e = draw.model.m

	-- safety: the record leaves out the matrix's fourth row, which still reads as the
	-- (0, 0, 0, 1) the shader puts back
	instance.model0x, instance.model0y, instance.model0z = e[0] * sx, e[1] * sx, e[2] * sx
	instance.model1x, instance.model1y, instance.model1z = e[4] * sy, e[5] * sy, e[6] * sy
	instance.model2x, instance.model2y, instance.model2z = e[8] * sz, e[9] * sz, e[10] * sz
	instance.model3x, instance.model3y, instance.model3z, instance.model3w =
		e[12] + px, e[13] + py, e[14] + pz, e[15]
end

---@type fun(draw: lupa.Draw, x: number, y: number, w: number, h: number)
function batch.emitRect(draw, x, y, w, h)
	local instance = batch.append(draw, meshes.rect)

	instance.model0x, instance.model0y, instance.model0z = w, 0, 0
	instance.model1x, instance.model1y, instance.model1z = 0, h, 0
	instance.model2x, instance.model2y, instance.model2z = 0, 0, 1
	instance.model3x, instance.model3y, instance.model3z, instance.model3w =
		x + w * 0.5, y + h * 0.5, 0, 1
end

---@type fun(draw: lupa.Draw)
function batch.breakBatch(draw)
	draw.lastRecordMesh = false
end

---@type fun(draw: lupa.Draw)
function batch.reset(draw)
	draw.instanceCount = 0
	draw.drawRecordCount = 0
	draw.lastRecordMesh = false
end

return batch
