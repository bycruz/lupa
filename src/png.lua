local ffi = require("ffi")

ffi.cdef [[
	int uncompress(unsigned char *dest, unsigned long *destLen,
	               const unsigned char *source, unsigned long sourceLen);
	unsigned long compressBound(unsigned long sourceLen);
	int compress2(unsigned char *dest, unsigned long *destLen,
	              const unsigned char *source, unsigned long sourceLen, int level);
]]

local zlib = ffi.load("z")

---@type ffi.ctype* unsigned char[?]
local byteArray = ffi.typeof("unsigned char[?]")

---@type ffi.ctype* unsigned long[?]
local ulongArray = ffi.typeof("unsigned long[?]")

---@type ffi.ctype* uint8_t[?]
local rgbaArray = ffi.typeof("uint8_t[?]")

---@type ffi.ctype* unsigned byte pointer, for ffi.cast
local bytePointer = ffi.typeof("const unsigned char*")

local PNG_SIGNATURE = "\137PNG\r\n\26\n"

-- safety: type 3 is the palette, whose colors come from the PLTE chunk rather than here
local FORMAT = {
	[0] = { channels = 1, gray = true },
	[2] = { channels = 3, r = 0, g = 1, b = 2 },
	[3] = { channels = 1 },
	[4] = { channels = 2, gray = true, a = 1 },
	[6] = { channels = 4, r = 0, g = 1, b = 2, a = 3 },
}

local M = {}

---@type fun(value: number): string
local function packU32(value)
	return string.char(math.floor(value / 16777216) % 256, math.floor(value / 65536) % 256,
		math.floor(value / 256) % 256, value % 256)
end

---@type number[]
local CRC_TABLE = {}
do
	-- safety: the table is built once rather than per chunk, and a PNG needs a checksum
	-- over every chunk it holds
	for index = 0, 255 do
		local value = index
		for _ = 1, 8 do
			value = bit.band(value, 1) == 1 and bit.bxor(0xEDB88320, bit.rshift(value, 1)) or bit.rshift(value, 1)
		end
		CRC_TABLE[index] = value
	end
end

---@type fun(s: string): number
local function crc32(s)
	local crc = 0xFFFFFFFF

	for index = 1, #s do
		crc = bit.bxor(CRC_TABLE[bit.band(bit.bxor(crc, s:byte(index)), 0xFF)], bit.rshift(crc, 8))
	end

	return bit.band(bit.bnot(crc), 0xFFFFFFFF)
end

--- One chunk: its length, its kind, its body and the checksum of the last two.
---@type fun(kind: string, body: string): string
local function chunk(kind, body)
	local payload = kind .. body
	return packU32(#body) .. payload .. packU32(crc32(payload))
end

---@type fun(s: string, i: number): number
local function u32(s, i)
	local a, b, c, d = s:byte(i, i + 3)
	a, b, c, d = assert(a), assert(b), assert(c), assert(d)
	return a * 16777216 + b * 65536 + c * 256 + d
end

---@type fun(a: number, b: number, c: number): number
local function paeth(a, b, c)
	local p = a + b - c
	local pa, pb, pc = math.abs(p - a), math.abs(p - b), math.abs(p - c)
	if pa <= pb and pa <= pc then
		return a
	elseif pb <= pc then
		return b
	end
	return c
end

---@type fun(raw: ffi.array<ffi.uint8_t>, height: number, stride: number, bpp: number)
local function unfilter(raw, height, stride, bpp)
	local pitch = stride + 1
	for y = 0, height - 1 do
		local row = y * pitch
		local filter = raw[row]
		local cur = row + 1
		local prev = cur - pitch

		if filter == 0 then
			-- safety: filter 0 needs no undo, and the empty branch keeps it out of the error below
		elseif filter == 1 then
			for x = bpp, stride - 1 do
				raw[cur + x] = (raw[cur + x] + raw[cur + x - bpp]) % 256
			end
		elseif filter == 2 then
			if y > 0 then
				for x = 0, stride - 1 do
					raw[cur + x] = (raw[cur + x] + raw[prev + x]) % 256
				end
			end
		elseif filter == 3 then
			for x = 0, stride - 1 do
				local a = x >= bpp and raw[cur + x - bpp] or 0
				local b = y > 0 and raw[prev + x] or 0
				raw[cur + x] = (raw[cur + x] + math.floor((a + b) / 2)) % 256
			end
		elseif filter == 4 then
			for x = 0, stride - 1 do
				local a = x >= bpp and raw[cur + x - bpp] or 0
				local b = y > 0 and raw[prev + x] or 0
				local c = (y > 0 and x >= bpp) and raw[prev + x - bpp] or 0
				raw[cur + x] = (raw[cur + x] + paeth(a, b, c)) % 256
			end
		else
			error("unsupported PNG filter type " .. filter)
		end
	end
end

---@param data string
---@return number width
---@return number height
---@return ffi.array<ffi.uint8_t> pixels
function M.decode(data)
	if #data < 8 or data:sub(1, 8) ~= PNG_SIGNATURE then
		error("not a PNG file (bad signature)")
	end

	---@type number?
	local width
	---@type number?
	local height
	---@type number?
	local bitDepth
	---@type number?
	local colorType
	---@type number?
	local interlace
	local palette, paletteLen = nil, 0
	local paletteAlpha = nil
	local idat = {}

	local pos = 9
	while pos + 7 <= #data do
		local len = u32(data, pos)
		local ctype = data:sub(pos + 4, pos + 7)
		local body = pos + 8

		if ctype == "IHDR" then
			width = u32(data, body)
			height = u32(data, body + 4)
			bitDepth = data:byte(body + 8)
			colorType = data:byte(body + 9)
			interlace = data:byte(body + 12)
		elseif ctype == "PLTE" then
			palette = data:sub(body, body + len - 1)
			paletteLen = len / 3
		elseif ctype == "tRNS" then
			paletteAlpha = data:sub(body, body + len - 1)
		elseif ctype == "IDAT" then
			idat[#idat + 1] = data:sub(body, body + len - 1)
		elseif ctype == "IEND" then
			break
		end

		pos = body + len + 4
	end

	if not width then
		error("PNG has no IHDR chunk")
	end
	assert(height, "PNG has no height in its IHDR chunk")
	if interlace ~= 0 then
		error("interlaced PNGs are not supported")
	end
	if bitDepth ~= 8 and bitDepth ~= 16 then
		error("unsupported PNG bit depth " .. tostring(bitDepth) .. " (1, 2 and 4 are not supported)")
	end

	local format = FORMAT[colorType]
	if not format then
		error("unsupported PNG color type " .. tostring(colorType))
	end

	local bpp = format.channels * (bitDepth / 8)
	local stride = width * bpp
	local rawLen = height * (stride + 1)

	local compressed = table.concat(idat)
	local src = ffi.cast(bytePointer, compressed)
	local raw = byteArray(rawLen)
	local outLen = ulongArray(1, rawLen)

	local result = zlib.uncompress(raw, outLen, src, #compressed)
	if result ~= 0 then
		-- safety: the buffer may simply have been too small, so retry with slack
		local bigger = byteArray(rawLen + 4096)
		local biggerLen = ulongArray(1, rawLen + 4096)
		result = zlib.uncompress(bigger, biggerLen, src, #compressed)
		if result ~= 0 then
			error("PNG IDAT stream failed to inflate (zlib error " .. result .. ")")
		end
		raw = bigger
	end

	unfilter(raw, height, stride, bpp)

	local pixels = rgbaArray(width * height * 4)
	local step = bitDepth == 16 and 2 or 1
	local pitch = stride + 1
	local out = 0

	for y = 0, height - 1 do
		local row = y * pitch + 1
		for x = 0, width - 1 do
			local base = row + x * bpp
			local r, g, b, a

			if colorType == 3 then
				local index = raw[base]
				if not palette or index >= paletteLen then
					r, g, b, a = 0, 0, 0, 255
				else
					local at = index * 3 + 1
					r, g, b = palette:byte(at, at + 2)
					a = (paletteAlpha and index < #paletteAlpha) and paletteAlpha:byte(index + 1) or 255
				end
			elseif format.gray then
				r = raw[base]
				g, b = r, r
				a = format.a and raw[base + format.a * step] or 255
			else
				r = raw[base + format.r * step]
				g = raw[base + format.g * step]
				b = raw[base + format.b * step]
				a = format.a and raw[base + format.a * step] or 255
			end

			pixels[out] = r
			pixels[out + 1] = g
			pixels[out + 2] = b
			pixels[out + 3] = a
			out = out + 4
		end
	end

	return width, height, pixels
end

--- The bytes of a PNG holding these pixels, which are rgba8 with a row at a time from the
--- top left, the way decode hands them back.
---
--- safety: this is what the loader reads, so what it writes and what it reads are one
--- format rather than two that agree today: 8 bits a channel, no interlacing, and one
--- filter of none per row
---@type fun(width: number, height: number, pixels: ffi.array<ffi.uint8_t>): string
function M.encode(width, height, pixels)
	local stride = width * 4
	local raw = byteArray(height * (stride + 1))

	for y = 0, height - 1 do
		raw[y * (stride + 1)] = 0
		ffi.copy(raw + y * (stride + 1) + 1, ffi.cast(bytePointer, pixels) + y * stride, stride)
	end

	local bound = zlib.compressBound(height * (stride + 1))
	local deflated = byteArray(bound)
	local length = ulongArray(1, { bound })
	local code = zlib.compress2(deflated, length, raw, height * (stride + 1), 6)
	if code ~= 0 then
		error("lupa: could not compress a PNG (zlib code " .. code .. ")")
	end

	local header = packU32(width) .. packU32(height) .. string.char(8, 6, 0, 0, 0)

	return PNG_SIGNATURE
		.. chunk("IHDR", header)
		.. chunk("IDAT", ffi.string(deflated, tonumber(length[0])))
		.. chunk("IEND", "")
end

return M
