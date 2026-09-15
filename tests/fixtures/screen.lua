--- A headless Draw, for tests that need to see what was drawn.
---
--- Nothing here needs a window: lupa renders into an offscreen target and the
--- frame is copied back to the CPU, so a test can assert on pixels through the
--- real path — projection, instancing, batching and all — anywhere the machine
--- can create a Vulkan device.
local Draw = require("lupa.draw")

local M = {}

---@class tests.Screen
---@field draw lupa.Draw
---@field width number
---@field height number
local Screen = {}
Screen.__index = Screen

---@param width number?
---@param height number?
---@return tests.Screen? screen
---@return string? error
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

--- Draw a frame and return an accessor for its pixels.
---
--- The accessor takes coordinates in the same space the 2D view uses: x from the
--- left, y counting up from the bottom. The capture comes back with rows from the
--- top, so the flip happens here once.
---@param paint fun(draw: lupa.Draw)
---@return fun(x: number, y: number): number, number, number, number
function Screen:render(paint)
	self:frame(paint)

	local width, height, pixels = self.draw:capturePixels()
	if not pixels then
		error("lupa: the frame was not captured")
	end

	return function(x, y)
		local i = ((height - 1 - y) * width + x) * 4 + 1
		return string.byte(pixels, i), string.byte(pixels, i + 1),
			string.byte(pixels, i + 2), string.byte(pixels, i + 3)
	end
end

return M
