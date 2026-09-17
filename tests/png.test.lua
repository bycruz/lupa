local ffi = require("ffi")
local png = require("lupa.png")
local test = require("lde-test")

--- Pixels that are not a flat colour, so a row or a channel written in the wrong place
--- shows up as a difference rather than as the same value over and over.
---@param width number
---@param height number
---@return ffi.cdata*
local function painted(width, height)
	local pixels = ffi.new("uint8_t[?]", width * height * 4)
	for index = 0, width * height * 4 - 1 do
		pixels[index] = (index * 37 + (index % 5) * 11) % 256
	end

	return pixels
end

test.it("png: what is written can be read back as the same pixels", function()
	for _, size in ipairs({ { 1, 1 }, { 3, 1 }, { 1, 3 }, { 7, 5 }, { 64, 33 } }) do
		local width, height = size[1], size[2]
		local pixels = painted(width, height)
		local data = png.encode(width, height, pixels)

		test.equal(data:sub(1, 8), "\137PNG\r\n\26\n")

		local readWidth, readHeight, readPixels = png.decode(data)
		test.equal(readWidth, width)
		test.equal(readHeight, height)

		local differences = 0
		for index = 0, width * height * 4 - 1 do
			if readPixels[index] ~= pixels[index] then
				differences = differences + 1
			end
		end

		test.equal(differences, 0)
	end
end)

test.it("png: a file written is a file that can be read", function()
	local width, height = 32, 16
	local pixels = painted(width, height)
	local path = "/tmp/lupa-png-test.png"

	local file = assert(io.open(path, "wb"))
	file:write(png.encode(width, height, pixels))
	file:close()

	local again = assert(io.open(path, "rb"))
	local data = again:read("*a")
	again:close()
	os.remove(path)

	local readWidth, readHeight, readPixels = png.decode(data)
	test.equal(readWidth, width)
	test.equal(readHeight, height)

	local differences = 0
	for index = 0, width * height * 4 - 1 do
		if readPixels[index] ~= pixels[index] then
			differences = differences + 1
		end
	end

	test.equal(differences, 0)
end)

test.it("png: an image that is not a PNG is refused", function()
	local ok = pcall(function()
		png.decode("this is not a png")
	end)

	test.falsy(ok)
end)
