--- A headless Draw, so a test can check what was drawn through the real path --
--- projection, instancing and batching included -- anywhere a device exists.
local Draw = require("lupa.draw")

local M = {}

--- A function returning the RGBA of one pixel, in the space the 2D view uses.
---@alias tests.Pixels fun(x: number, y: number): number, number, number, number

---@class tests.Screen
---@field draw lupa.Draw
---@field width number
---@field height number
local Screen = {}
Screen.__index = Screen

---@type fun(width: number?, height: number?): tests.Screen?, string?
function M.new(width, height)
	local ok, screenOrError = pcall(function()
		return setmetatable({
			width = width or 200,
			height = height or 200,
			draw = Draw.new(nil, {
				headless = true,
				width = width or 200,
				height = height or 200,
			}),
		}, Screen)
	end)

	if not ok then
		return nil, tostring(screenOrError)
	end

	---@type tests.Screen
	return screenOrError
end

--- Draw one frame.
---@param paint fun(draw: lupa.Draw)
function Screen:frame(paint)
	self.draw:beginFrame()
	paint(self.draw)
	self.draw:endFrame()
end

--- Draw a frame and return an accessor for its pixels, in the same space the 2D
--- view uses: x from the left, y counting up from the bottom.
---@param paint fun(draw: lupa.Draw)
---@return tests.Pixels
function Screen:render(paint)
	self:frame(paint)

	local width, height, pixels = self.draw:capturePixels()
	if not pixels then
		error("lupa: the frame was not captured")
	end

	-- safety: the capture comes back with rows from the top, so the flip happens
	-- here once instead of in every test
	return function(x, y)
		local i = ((height - 1 - y) * width + x) * 4 + 1
		return string.byte(pixels, i), string.byte(pixels, i + 1),
			string.byte(pixels, i + 2), string.byte(pixels, i + 3)
	end
end

--- Assert the color at (x, y), to within the tolerance of reading a frame back
--- through 8 bit channels.
---@param pixels tests.Pixels
---@param label string
---@param x number
---@param y number
---@param r number 0..1
---@param g number 0..1
---@param b number 0..1
function M.expectAt(pixels, label, x, y, r, g, b)
	local pr, pg, pb = pixels(x, y)
	local got = { pr, pg, pb }
	local want = { r * 255, g * 255, b * 255 }

	for i = 1, 3 do
		if math.abs(got[i] - want[i]) > 8 then
			error(string.format("%s: got (%d, %d, %d), want (%d, %d, %d)",
				label, got[1], got[2], got[3], want[1], want[2], want[3]))
		end
	end
end

return M
