--- Minimal PNG decoder: 8- and 16-bit, non-interlaced, color types 0/2/3/4/6.
---
--- Deliberately dependency-free: it parses the chunks itself and uses the
--- system zlib's one-shot `uncompress` for the IDAT stream, so there is no
--- build step and no C module to ship.
local ffi = require("ffi")

ffi.cdef [[
	int uncompress(unsigned char *dest, unsigned long *destLen,
	               const unsigned char *source, unsigned long sourceLen);
]]

local zlib = ffi.load("z")

local PNG_SIGNATURE = "\137PNG\r\n\26\n"

local M = {}

---@param s string
---@param i number 1-based
local function u32(s, i)
	local a, b, c, d = s:byte(i, i + 3)
	return a * 16777216 + b * 65536 + c * 256 + d
end

local function paeth(a, b, c)
	local p = a + b - c
	local pa, pb, pc = math.abs(p - a), math.abs(p - b), math.abs(p - c)
	if pa <= pb and pa <= pc then return a end
	if pb <= pc then return b end
	return c
end

--- Undo the per-scanline filters in place. `raw` holds height * stride bytes,
--- each scanline prefixed with its filter type byte.
local function unfilter(raw, height, stride, bpp)
	-- Each scanline is its filter byte followed by `stride` bytes of data, so
	-- the row pitch is stride + 1, not stride.
	local pitch = stride + 1
	for y = 0, height - 1 do
		local row = y * pitch
		local filter = raw[row]
		local cur = row + 1
		local prev = cur - pitch

		if filter == 0 then
			-- nothing
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

---@param data string raw file contents
---@return number width, number height, ffi.cdata* rgba
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
		error("unsupported PNG bit depth " .. tostring(bitDepth) ..
			" (1, 2 and 4 are not supported)")
	end

	local channels
	if colorType == 0 then channels = 1
	elseif colorType == 2 then channels = 3
	elseif colorType == 3 then channels = 1
	elseif colorType == 4 then channels = 2
	elseif colorType == 6 then channels = 4
	else
		error("unsupported PNG color type " .. tostring(colorType))
	end

	local bpp = channels * (bitDepth / 8)
	local stride = width * bpp
	local rawLen = height * (stride + 1)

	local compressed = table.concat(idat)
	local src = ffi.cast("const unsigned char *", compressed)
	local raw = ffi.new("unsigned char[?]", rawLen)
	local outLen = ffi.new("unsigned long[1]", rawLen)

	local result = zlib.uncompress(raw, outLen, src, #compressed)
	if result ~= 0 then
		-- The buffer may simply have been too small; retry with slack.
		local bigger = ffi.new("unsigned char[?]", rawLen + 4096)
		local biggerLen = ffi.new("unsigned long[1]", rawLen + 4096)
		result = zlib.uncompress(bigger, biggerLen, src, #compressed)
		if result ~= 0 then
			error("PNG IDAT stream failed to inflate (zlib error " .. result .. ")")
		end
		raw = bigger
	end

	unfilter(raw, height, stride, bpp)

	-- Expand to tightly packed RGBA8.
	local pixels = ffi.new("uint8_t[?]", width * height * 4)
	local high = bitDepth == 16 and 2 or 1 -- step between samples
	local out = 0

	local pitch = stride + 1
	for y = 0, height - 1 do
		local row = y * pitch + 1
		for x = 0, width - 1 do
			local base = row + x * bpp
			local r, g, b, a

			if colorType == 6 then
				r, g, b, a = raw[base], raw[base + high], raw[base + high * 2], raw[base + high * 3]
			elseif colorType == 2 then
				r, g, b, a = raw[base], raw[base + high], raw[base + high * 2], 255
			elseif colorType == 4 then
				r = raw[base]; g = r; b = r; a = raw[base + high]
			elseif colorType == 0 then
				r = raw[base]; g = r; b = r; a = 255
			else -- palette
				local idx = raw[base]
				if idx >= paletteLen then
					r, g, b, a = 0, 0, 0, 255
				else
					local p = idx * 3 + 1
					r, g, b = palette:byte(p, p + 2)
					a = (paletteAlpha and idx < #paletteAlpha)
						and paletteAlpha:byte(idx + 1) or 255
				end
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
