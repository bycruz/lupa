local ffi = require("ffi")

local gpu = require("lupa.draw.gpu")
local limits = require("lupa.draw.limits")
local meshes = require("lupa.draw.meshes")
local records = require("lupa.draw.records")

--- Bytes one vertex takes in the arena: 8 floats in, 24 bytes stored, because the
--- normal fits in three signed normalized bytes that the shader normalizes away.
local PACKED_VERTEX_BYTES = 24
local SOURCE_VERTEX_FLOATS = 8
local INDEX_BYTES = 4

---@type ffi.ctype* float pointer, cached because ffi.cast and ffi.new would
--- otherwise parse the type string on every call
local floatPointer = ffi.typeof("float*")

---@type ffi.ctype* unsigned byte pointer
local bytePointer = ffi.typeof("uint8_t*")

---@type ffi.ctype* uint8_t[?]
local byteArray = ffi.typeof("uint8_t[?]")

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

---@type fun(mesh: lupa.Mesh, scratch: ffi.cdata*)
local function packVertices(mesh, scratch)
	local source = ffi.cast(floatPointer, mesh.vertices)
	local floats = ffi.cast(floatPointer, scratch)
	local bytes = ffi.cast(bytePointer, scratch)

	for i = 0, mesh.vertexCount - 1 do
		local src = i * SOURCE_VERTEX_FLOATS
		local dst = i * 6 -- 24 bytes read as six floats
		local normal = i * PACKED_VERTEX_BYTES + 12

		floats[dst] = source[src]
		floats[dst + 1] = source[src + 1]
		floats[dst + 2] = source[src + 2]
		bytes[normal] = snormByte(source[src + 3])
		bytes[normal + 1] = snormByte(source[src + 4])
		bytes[normal + 2] = snormByte(source[src + 5])
		bytes[normal + 3] = 0
		floats[dst + 4] = source[src + 6]
		floats[dst + 5] = source[src + 7]
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

--- A mesh's place in the arenas, in vertices and in indices.
---@class lupa.draw.Placement
---@field vertexBase number
---@field indexBase number
---@field vertexBytes number
---@field indexBytes number

---@class lupa.draw.Arena
---@field vertexBuffer hood.Buffer
---@field indexBuffer hood.Buffer
---@field vertexCapacity number bytes
---@field indexCapacity number bytes
---@field vertexUsed number bytes
---@field indexUsed number bytes
---@field placements table<lupa.Mesh, lupa.draw.Placement>
---@field scratch ffi.cdata*|false
---@field scratchBytes number

---@class lupa.draw.Batch
---@field newArena fun(device: hood.Device): lupa.draw.Arena
---@field placeMesh fun(draw: lupa.Draw, mesh: lupa.Mesh): number vertexBase, number indexBase
---@field append fun(draw: lupa.Draw, mesh: lupa.Mesh): lupa.draw.Instance
---@field emit fun(draw: lupa.Draw, mesh: lupa.Mesh, px: number, py: number, pz: number, sx: number, sy: number, sz: number)
---@field emitRect fun(draw: lupa.Draw, x: number, y: number, w: number, h: number)
---@field reset fun(draw: lupa.Draw)
local batch = {}

--- Every mesh's vertices and indices in one buffer each: a draw selects a mesh by
--- where it sits in the arena.
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
		-- safety: placement belongs to the arena, because a mesh is shared by every draw
		placements = setmetatable({}, { __mode = "k" }),
		scratch = false,
		scratchBytes = 0,
	}
end

--- Put a mesh in the arenas if it is not there yet, and say where it landed.
---@type fun(draw: lupa.Draw, mesh: lupa.Mesh): number, number
function batch.placeMesh(draw, mesh)
	local arena, device = draw.arena, draw.device
	local placement = arena.placements[mesh]
	if placement then
		return placement.vertexBase, placement.indexBase
	end

	local vertexBytes = mesh.vertexCount * PACKED_VERTEX_BYTES
	local indexBytes = mesh.indexCount * INDEX_BYTES
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

		-- safety: a placed mesh keeps its offset, so growth only re-uploads, and the
		-- old buffers go once the queue drains
		for other, at in pairs(arena.placements) do
			local scratch = scratchFor(arena, other.vertexCount)
			packVertices(other, scratch)
			gpu.upload(device, arena.vertexBuffer, other.vertexCount * PACKED_VERTEX_BYTES, scratch, at.vertexBytes)
			gpu.upload(device, arena.indexBuffer, other.indexCount * INDEX_BYTES, other.indices, at.indexBytes)
		end

		oldVertex:destroy()
		oldIndex:destroy()
	end

	placement = {
		vertexBase = arena.vertexUsed / PACKED_VERTEX_BYTES,
		indexBase = arena.indexUsed / INDEX_BYTES,
		vertexBytes = arena.vertexUsed,
		indexBytes = arena.indexUsed,
	}
	arena.placements[mesh] = placement

	local packed = scratchFor(arena, mesh.vertexCount)
	packVertices(mesh, packed)
	gpu.upload(device, arena.vertexBuffer, vertexBytes, packed, arena.vertexUsed)
	gpu.upload(device, arena.indexBuffer, indexBytes, mesh.indices, arena.indexUsed)

	arena.vertexUsed = arena.vertexUsed + vertexBytes
	arena.indexUsed = arena.indexUsed + indexBytes

	return placement.vertexBase, placement.indexBase
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

--- Add one instance of a mesh to the frame and return the record to fill in.
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

--- Draw one copy of a mesh at a position and scale, through the model matrix.
---@type fun(draw: lupa.Draw, mesh: lupa.Mesh, px: number, py: number, pz: number, sx: number, sy: number, sz: number)
function batch.emit(draw, mesh, px, py, pz, sx, sy, sz)
	if mesh.vertexCount == 0 or mesh.indexCount == 0 then
		return
	end

	local instance = batch.append(draw, mesh)
	local e = draw.model.m

	-- safety: the row the record leaves out still reads as the (0, 0, 0, 1) the
	-- shader puts back, because scaling keeps a column's fourth component at zero
	-- and adding a position keeps the translation column's at one
	instance.model0x, instance.model0y, instance.model0z = e[0] * sx, e[1] * sx, e[2] * sx
	instance.model1x, instance.model1y, instance.model1z = e[4] * sy, e[5] * sy, e[6] * sy
	instance.model2x, instance.model2y, instance.model2z = e[8] * sz, e[9] * sz, e[10] * sz
	instance.model3x, instance.model3y, instance.model3z, instance.model3w =
		e[12] + px, e[13] + py, e[14] + pz, e[15]
end

--- Draw a rectangle in 2D units: the quad is unit sized, so the matrix is its
--- size and centre, and the model stack does not apply.
---@type fun(draw: lupa.Draw, x: number, y: number, w: number, h: number)
function batch.emitRect(draw, x, y, w, h)
	local instance = batch.append(draw, meshes.rect)

	instance.model0x, instance.model0y, instance.model0z = w, 0, 0
	instance.model1x, instance.model1y, instance.model1z = 0, h, 0
	instance.model2x, instance.model2y, instance.model2z = 0, 0, 1
	instance.model3x, instance.model3y, instance.model3z, instance.model3w =
		x + w * 0.5, y + h * 0.5, 0, 1
end

--- Start a frame with no geometry in it.
---@type fun(draw: lupa.Draw)
function batch.reset(draw)
	draw.instanceCount = 0
	draw.drawRecordCount = 0
	draw.lastRecordMesh = false
end

return batch
