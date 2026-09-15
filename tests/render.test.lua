--- Rendering through lupa's real path, checked by reading pixels back.
---
--- These cover what the design is responsible for rather than the shader alone:
--- the 2D view's orientation, rectangles going through instancing, the batching
--- rule, meshes, and the empty frame that used to take the driver down with it.
local ffi = require("ffi")
local test = require("lde-test")
local Assets = require("lupa.assets")
local screenFixture = require("tests.fixtures.screen")

-- Rendering is headless, so these need no window: the frame goes to an offscreen
-- target and is read back.
local screen, screenError = screenFixture.new(400, 300)
local screenIt = test.skipIf(screen == nil)

if not screen then
	test.skip("render: skipped, no device available (" .. tostring(screenError) .. ")", function() end)
	return
end

local W, H = screen.width, screen.height

---@param label string
---@param got number[]
---@param want number[]
local function checkColor(label, got, want)
	for i = 1, 3 do
		if math.abs(got[i] - want[i]) > 8 then
			error(string.format("%s: got (%d, %d, %d), want (%d, %d, %d)",
				label, got[1], got[2], got[3], want[1], want[2], want[3]))
		end
	end
end

---@param pixels fun(x: number, y: number): number, number, number, number
---@param label string
---@param x number
---@param y number
---@param r number 0..1
---@param g number 0..1
---@param b number 0..1
local function expectAt(pixels, label, x, y, r, g, b)
	local pr, pg, pb = pixels(x, y)
	checkColor(label, { pr, pg, pb }, { r * 255, g * 255, b * 255 })
end

--- A 2x2 texture with four distinct colors: red and green across the top,
--- blue and yellow across the bottom.
local function uploadTexels(draw)
	local texels = ffi.new("uint8_t[16]", {
		255, 0, 0, 255, 0, 255, 0, 255,
		0, 0, 255, 255, 255, 255, 0, 255,
	})

	return draw:addTexture(2, 2, texels)
end

screenIt("render: a rect lands where the 2D view says it does", function()
	local pixels = screen:render(function(d)
		d:setColor(0.2, 0.2, 0.6, 1)
		d:rect(0, 0, W, H)

		d:setColor(1, 0, 0, 1)
		d:rect(50, 50, 100, 100)
	end)

	expectAt(pixels, "inside", 100, 100, 1, 0, 0)
	expectAt(pixels, "left of it", 20, 100, 0.2, 0.2, 0.6)
	expectAt(pixels, "below it", 100, 20, 0.2, 0.2, 0.6)
	expectAt(pixels, "above it", 100, 200, 0.2, 0.2, 0.6)
	expectAt(pixels, "right of it", 200, 100, 0.2, 0.2, 0.6)
end)

screenIt("render: y = 0 is the bottom of the window", function()
	local pixels = screen:render(function(d)
		d:setColor(0, 0, 0, 1)
		d:rect(0, 0, W, H)

		d:setColor(0, 1, 0, 1)
		d:rect(0, 0, W, 10)
	end)

	expectAt(pixels, "bottom edge", 100, 1, 0, 1, 0)
	expectAt(pixels, "top edge", 100, H - 2, 0, 0, 0)
end)

screenIt("render: a frame of many objects is one draw call", function()
	local records, instances
	screen:frame(function(d)
		for i = 1, 500 do
			d:setColor(0.5, 0.5, 0.5, 1)
			d:rect(i % 300, i % 200, 8, 8)
		end

		instances = d.instanceCount
		records = d.drawRecordCount
	end)

	test.equal(instances, 500)
	-- Rectangles share a mesh and a texture, so they batch into one command, and
	-- the frame issues one indirect call over all of them.
	test.equal(records, 1)
end)

screenIt("render: a texture change starts a new draw command", function()
	local afterRects, afterTexture, afterClear
	screen:frame(function(d)
		d:setColor(1, 1, 1, 1)
		d:rect(0, 0, 10, 10)
		d:rect(20, 0, 10, 10)
		afterRects = d.drawRecordCount

		d:setTexture(uploadTexels(d))
		d:rect(40, 0, 10, 10)
		afterTexture = d.drawRecordCount

		d:clearTexture()
		d:rect(60, 0, 10, 10)
		afterClear = d.drawRecordCount
	end)

	test.equal(afterRects, 1)
	test.equal(afterTexture, 2)
	test.equal(afterClear, 3)
end)

screenIt("render: an empty frame clears", function()
	-- The case that used to crash: with nothing to draw, the pipeline was never
	-- bound, so the render pass was never started.
	local pixels = screen:render(function() end)

	expectAt(pixels, "cleared corner", 5, 5, 0.1, 0.1, 0.1)
	expectAt(pixels, "cleared middle", math.floor(W / 2), math.floor(H / 2), 0.1, 0.1, 0.1)
end)

screenIt("render: a texture is sampled across the rect", function()
	local pixels = screen:render(function(d)
		d:setColor(0, 0, 0, 1)
		d:rect(0, 0, W, H)

		-- A texture is multiplied by the current color, so showing the image
		-- itself takes white rather than the background's black.
		d:setColor(1, 1, 1, 1)
		d:setTexture(uploadTexels(d))
		d:rect(100, 100, 200, 200)
	end)

	-- Each texel gets a 100x100 quadrant. v = 0 is the top edge of the rect, so
	-- the image's first row is the upper half.
	expectAt(pixels, "top left texel, red", 150, 250, 1, 0, 0)
	expectAt(pixels, "top right texel, green", 250, 250, 0, 1, 0)
	expectAt(pixels, "bottom left texel, blue", 150, 150, 0, 0, 1)
	expectAt(pixels, "bottom right texel, yellow", 250, 150, 1, 1, 0)
end)

screenIt("render: setTextureRect samples only the part it names", function()
	local pixels = screen:render(function(d)
		d:setColor(0, 0, 0, 1)
		d:rect(0, 0, W, H)

		d:setColor(1, 1, 1, 1)
		d:setTexture(uploadTexels(d))
		d:setTextureRect(0.5, 0, 1, 1) -- the right half: green over yellow
		d:rect(100, 100, 200, 200)
	end)

	-- The sampled rectangle travels per instance, so the whole quad shows the
	-- right half of the texture and nothing of the left. Sampling is linear, so
	-- the samples go through texel centres: the image's two texels span x
	-- 100..300, putting their centres at 200 and the boundaries on the hundreds.
	expectAt(pixels, "upper half, green", 200, 250, 0, 1, 0)
	expectAt(pixels, "lower half, yellow", 200, 150, 1, 1, 0)
end)

screenIt("render: a mesh is drawn at the position it was given", function()
	local assets = Assets.new(screen.draw)

	local triangle = assets:mesh({
		-10, -10, 0, 0, 0, 1, 0, 0,
		 10, -10, 0, 0, 0, 1, 1, 0,
		  0,  10, 0, 0, 0, 1, 0.5, 1,
	}, { 0, 1, 2 })

	local pixels = screen:render(function(d)
		d:setColor(0, 0, 0, 1)
		d:rect(0, 0, W, H)

		-- Texture state is sticky, and earlier tests selected one, so this asks
		-- for flat color explicitly to test the mesh rather than the atlas.
		d:clearTexture()
		d:setColor(0, 1, 1, 1)
		d:mesh(triangle, 200, 200, 0)
	end)

	-- The orthographic view keeps meshes in the same units as the 2D drawing, so
	-- the triangle covers a small area around (200, 200).
	expectAt(pixels, "inside the triangle", 200, 195, 0, 1, 1)
	expectAt(pixels, "above it", 200, 215, 0, 0, 0)
	expectAt(pixels, "left of it", 180, 195, 0, 0, 0)
end)

screenIt("render: lighting reads the mesh normals", function()
	-- Rects face +Z. `direction` is the way the light travels, so a light
	-- heading away from the camera shines along -Z and hits them head on, while
	-- one heading towards the camera leaves only the ambient term. The normals
	-- reach the shader as packed signed normalized bytes, which is what this
	-- pins down: a mis-decoded normal would shade the rect by some other angle.
	local facing = screen:render(function(d)
		d:setColor(1, 1, 1, 1)
		d:clearTexture()
		d:setLight({ direction = { 0, 0, -1 }, color = { 1, 1, 1 }, ambient = { 0, 0, 0 } })
		d:rect(0, 0, W, H)
	end)

	-- Travelling towards the camera: the normal faces away, so diffuse is zero.
	local away = screen:render(function(d)
		d:setColor(1, 1, 1, 1)
		d:clearTexture()
		d:setLight({ direction = { 0, 0, 1 }, color = { 1, 1, 1 }, ambient = { 0.25, 0, 0 } })
		d:rect(0, 0, W, H)
	end)

	expectAt(facing, "lit head on", 100, 100, 1, 1, 1)
	expectAt(away, "lit from behind", 100, 100, 0.25, 0, 0)
end)

screenIt("render: capturePixels reports when there is nothing captured", function()
	local first = screen.draw:capturePixels()
	test.equal(first, nil)
end)
