--- Minimal PNG decoder, 8- and 16-bit non-interlaced, over the system zlib.
local ffi = require("ffi")

ffi.cdef [[
	int uncompress(unsigned char *dest, unsigned long *destLen,
	               const unsigned char *source, unsigned long sourceLen);
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

--- Channels per pixel and where each channel sits, by PNG color type. Type 3 is
--- the palette, whose colors come from the PLTE chunk.
local FORMAT = {
	[0] = { channels = 1, gray = true },
	[2] = { channels = 3, r = 0, g = 1, b = 2 },
	[3] = { channels = 1 },
	[4] = { channels = 2, gray = true, a = 1 },
	[6] = { channels = 4, r = 0, g = 1, b = 2, a = 3 },
}

local M = {}

---@type fun(s: string, i: number): number
local function u32(s, i)
	local a, b, c, d = s:byte(i, i + 3)
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

--- Undo the per-scanline filters in place.
---@type fun(raw: ffi.cdata*, height: number, stride: number, bpp: number)
local function unfilter(raw, height, stride, bpp)
	local pitch = stride + 1
	for y = 0, height - 1 do
		local row = y * pitch
		local filter = raw[row]
		local cur = row + 1
		local prev = cur - pitch

		if filter == 0 then
			-- no filter
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

---@type fun(data: string): number, number, ffi.cdata*
function M.decode(data)
	if #data < 8 or data:sub(1, 8) ~= PNG_SIGNATURE then
		error("not a PNG file (bad signature)")
	end

	local width, height, bitDepth, colorType, interlace
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

return M
