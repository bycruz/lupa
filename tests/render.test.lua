local ffi = require("ffi")
local test = require("lde-test")
local Assets = require("lupa.assets")
local screenFixture = require("tests.fixtures.screen")

-- safety: rendering is headless, so these need no window: the frame goes to an
-- offscreen target and is read back.
local screen, screenError = screenFixture.new(400, 300)
local screenIt = test.skipIf(screen == nil)

if not screen then
	test.skip("render: skipped, no device available (" .. tostring(screenError) .. ")", function() end)
	return
end

local W, H = screen.width, screen.height
local expectAt = screenFixture.expectAt

--- A 2x2 texture with four distinct colors: red and green across the top, blue
--- and yellow across the bottom.
---@type fun(draw: lupa.Draw): number
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
	-- Rectangles share a mesh and a texture, so they batch into one command.
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
	local pixels = screen:render(function() end)

	expectAt(pixels, "cleared corner", 5, 5, 0.1, 0.1, 0.1)
	expectAt(pixels, "cleared middle", math.floor(W / 2), math.floor(H / 2), 0.1, 0.1, 0.1)
end)

screenIt("render: a texture is sampled across the rect", function()
	local pixels = screen:render(function(d)
		d:setColor(0, 0, 0, 1)
		d:rect(0, 0, W, H)

		-- safety: a texture is multiplied by the current color, so showing the
		-- image itself takes white rather than the background's black
		d:setColor(1, 1, 1, 1)
		d:setTexture(uploadTexels(d))
		d:rect(100, 100, 200, 200)
	end)

	-- Each texel gets a 100x100 quadrant, and v = 0 is the top edge of the rect.
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

	-- The sampled rectangle travels per instance, and sampling is linear, so the
	-- samples go through texel centres at x = 200.
	expectAt(pixels, "upper half, green", 200, 250, 0, 1, 0)
	expectAt(pixels, "lower half, yellow", 200, 150, 1, 1, 0)
end)

screenIt("render: a minified texture keeps its channels and keeps its tiles apart", function()
	-- safety: the smaller levels are built by filtering texels together, so a level
	-- that reads a neighbouring channel or filters across the join between two tiles
	-- of a block changes what colour the block is with distance, not just its detail
	local tiles = {}
	for _, color in ipairs({ { 200, 30, 10 }, { 10, 200, 30 }, { 30, 10, 200 } }) do
		for _ = 1, 32 * 32 do
			tiles[#tiles + 1] = color[1]
			tiles[#tiles + 1] = color[2]
			tiles[#tiles + 1] = color[3]
			tiles[#tiles + 1] = 255
		end
	end

	local pixels = screen:render(function(d)
		d:setColor(0, 0, 0, 1)
		d:rect(0, 0, W, H)

		d:setColor(1, 1, 1, 1)
		d:setTexture(d:addTexture(32, 96, ffi.new("uint8_t[?]", #tiles, tiles), { rows = 3 }))
		-- half size, so the samples land between texels and take the next level down
		d:rect(100, 100, 16, 48)
	end)

	expectAt(pixels, "the top tile", 108, 140, 200 / 255, 30 / 255, 10 / 255)
	expectAt(pixels, "the middle tile", 108, 124, 10 / 255, 200 / 255, 30 / 255)
	expectAt(pixels, "the bottom tile", 108, 108, 30 / 255, 10 / 255, 200 / 255)
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

		-- safety: texture state is sticky and earlier tests selected one, so this
		-- asks for flat color to test the mesh rather than the atlas
		d:clearTexture()
		d:setColor(0, 1, 1, 1)
		d:mesh(triangle, 200, 200, 0)
	end)

	expectAt(pixels, "inside the triangle", 200, 195, 0, 1, 1)
	expectAt(pixels, "above it", 200, 215, 0, 0, 0)
	expectAt(pixels, "left of it", 180, 195, 0, 0, 0)
end)

screenIt("render: lighting reads the mesh normals", function()
	-- safety: this pins down the packed signed normalized normals, since a
	-- mis-decoded one would shade the rect by some other angle
	local facing = screen:render(function(d)
		d:setColor(1, 1, 1, 1)
		d:clearTexture()
		d:setLighting({ ambient = { 0, 0, 0 }, lights = { { dir = { 0, 0, -1 }, color = { 1, 1, 1 } } } })
		d:rect(0, 0, W, H)
	end)

	-- Travelling towards the camera: the normal faces away, so diffuse is zero.
	local away = screen:render(function(d)
		d:setColor(1, 1, 1, 1)
		d:clearTexture()
		d:setLighting({ ambient = { 0.25, 0, 0 }, lights = { { dir = { 0, 0, 1 }, color = { 1, 1, 1 } } } })
		d:rect(0, 0, W, H)
	end)

	expectAt(facing, "lit head on", 100, 100, 1, 1, 1)
	expectAt(away, "lit from behind", 100, 100, 0.25, 0, 0)
end)

screenIt("render: capturePixels reports when there is nothing captured", function()
	local first = screen.draw:capturePixels()
	test.equal(first, nil)
end)

screenIt("render: a mesh that is rebuilt is drawn from its new vertices", function()
	local assets = Assets.new(screen.draw)
	local mesh = assets:mesh({
		-10, -10, 0, 0, 0, 1, 0, 0,
		 10, -10, 0, 0, 0, 1, 1, 0,
		  0,  10, 0, 0, 0, 1, 0.5, 1,
	}, { 0, 1, 2 })

	local function frame()
		return screen:render(function(d)
			d:setOrtho()
			d:clearLighting()
			d:clearTexture()
			d:setColor(0, 0, 0, 1)
			d:rect(0, 0, W, H)

			d:setColor(0, 1, 1, 1)
			d:mesh(mesh, 200, 200, 0)
		end)
	end

	local before = frame()
	expectAt(before, "above the small triangle", 200, 230, 0, 0, 0)

	mesh:update({
		-40, -40, 0, 0, 0, 1, 0, 0,
		 40, -40, 0, 0, 0, 1, 1, 0,
		  0,  40, 0, 0, 0, 1, 0.5, 1,
	}, { 0, 1, 2 })

	local after = frame()
	expectAt(after, "the rebuilt triangle covers that point", 200, 230, 0, 1, 1)
	expectAt(after, "and the old one is inside it", 200, 195, 0, 1, 1)
end)

screenIt("render: a released mesh hands its room in the arena to the next one", function()
	local assets = Assets.new(screen.draw)
	local arena = screen.draw.arena

	---@type number[]
	local vertices = { -10, -10, 0, 0, 0, 1, 0, 0, 10, -10, 0, 0, 0, 1, 1, 0, 0, 10, 0, 0, 0, 1, 0.5, 1 }
	---@type number[]
	local indices = { 0, 1, 2 }

	---@type fun(mesh: lupa.Mesh): tests.Pixels
	local function paint(mesh)
		return screen:render(function(d)
			d:setOrtho()
			d:clearLighting()
			d:clearTexture()
			d:setColor(0, 0, 0, 1)
			d:rect(0, 0, W, H)

			d:setColor(0, 1, 1, 1)
			d:mesh(mesh, 200, 200, 0)
		end)
	end

	local first = assets:mesh(vertices, indices)
	paint(first)
	local used = arena.vertexUsed

	screen.draw:releaseMesh(first)
	test.greater(#arena.freeVertices, 0)

	local pixels = paint(assets:mesh(vertices, indices))
	test.equal(arena.vertexUsed, used)
	expectAt(pixels, "the triangle the second mesh drew", 200, 195, 0, 1, 1)
end)

screenIt("render: a frame that outgrows its starting capacity still draws", function()
	local assets = Assets.new(screen.draw)
	---@type lupa.Mesh[]
	local meshes = {}

	for i = 1, 300 do
		meshes[i] = assets:mesh({
			-10, -10, 0, 0, 0, 1, 0, 0,
			 10, -10, 0, 0, 0, 1, 1, 0,
			  0,  10, 0, 0, 0, 1, 0.5, 1,
		}, { 0, 1, 2 })
	end

	local pixels = screen:render(function(d)
		d:setOrtho()
		d:clearTexture()
		d:setColor(0, 0, 0, 1)
		d:rect(0, 0, W, H)

		-- safety: this is what the frame slots are rebuilt for, and a rebuilt slot
		-- that is missing its shadow bind group fails in the shadow pass
		d:setLighting({ lights = { { dir = { 0, 0, -1 }, color = { 1, 1, 1 }, shadows = true } } })
		d:setColor(0, 1, 1, 1)

		for _, mesh in ipairs(meshes) do
			d:mesh(mesh, 200, 200, 0)
		end
	end)

	-- 300 meshes are 300 draw commands, so the slots were rebuilt at a bigger size
	test.greater(screen.draw.drawRecordCapacity, 256)
	expectAt(pixels, "the last mesh drawn", 200, 195, 0, 1, 1)
end)

screenIt("render: the overlay is drawn in the 2D view and unlit", function()
	local pixels = screen:render(function(d)
		d:setOrtho()

		-- The light faces away from the 2D rects, so anything lit comes out black.
		d:setLighting({ ambient = { 0, 0, 0 }, lights = { { dir = { 0, 0, 1 }, color = { 1, 1, 1 } } } })
		d:clearTexture()
		d:setColor(1, 1, 1, 1)
		d:rect(0, 0, W, H)

		d:beginOverlay()
		d:setColor(0, 1, 0, 1)
		d:rect(0, 0, 60, 60)
	end)

	expectAt(pixels, "the unlit overlay keeps its color", 30, 30, 0, 1, 0)
	expectAt(pixels, "the lit scene behind it is dark", 200, 150, 0, 0, 0)
end)

screenIt("render: only what is drawn before endShadowCasters casts a shadow", function()
	---@param limited boolean
	---@return tests.Pixels
	local function scene(limited)
		return screen:render(function(d)
			d:setOrtho()
			d:clearTexture()

			-- looking down at a plane, with a box standing on it: the plane behind the
			-- box is the one the shadow falls on
			d:setCamera({ position = { 0, 12, 0 }, target = { 0, 0, 0 }, up = { 0, 0, -1 } })
			d:setLighting({ ambient = { 0.05, 0.05, 0.05 }, lights = { { dir = { 1, -1, 0 }, color = { 1, 1, 1 }, shadows = true } } })
			d:setColor(1, 1, 1, 1)
			d:plane(0, 0, 0, 20, 20)

			if limited then
				d:endShadowCasters()
			end

			d:cube(0, 1, 0, 2)
		end)
	end

	---@param pixels tests.Pixels
	---@return number
	local function brightness(pixels)
		local r, g, b = pixels(200 + 30, 150)
		return (r + g + b) / 3
	end

	local cast = brightness(scene(false))
	local notCasting = brightness(scene(true))

	test.less(cast, 60)
	test.greater(notCasting, 150)
end)

screenIt("render: a tiled vertex samples the tile it names, and repeats it", function()
	-- One layer, three tiles down it: the top is red, the middle has a dark left half
	-- and a bright right half, the bottom is blue. A quad naming the middle tile twice
	-- across must show dark then bright then dark again.
	local texels = ffi.new("uint8_t[16 * 48 * 4]")
	local function set(x, y, r, g, b)
		local i = (y * 16 + x) * 4
		texels[i], texels[i + 1], texels[i + 2], texels[i + 3] = r, g, b, 255
	end
	for y = 0, 47 do
		for x = 0, 15 do
			if y < 16 then
				set(x, y, 255, 0, 0)
			elseif y < 32 then
				local bright = x >= 8 and 255 or 0
				set(x, y, bright, bright, bright)
			else
				set(x, y, 0, 0, 255)
			end
		end
	end

	local draw = screen.draw
	local layer = draw:addTexture(16, 48, texels)

	--- A 10 pixel quad whose uv counts two tiles across and one down.
	---@param tile number
	---@return lupa.Mesh
	local function quad(tile)
		return Assets.new(draw):mesh({
			0, 0, 0, 0, 0, 1, 0, 1, tile,
			10, 0, 0, 0, 0, 1, 2, 1, tile,
			10, 10, 0, 0, 0, 1, 2, 0, tile,
			0, 10, 0, 0, 0, 1, 0, 0, tile,
		}, { 0, 1, 2, 0, 2, 3 }, 9)
	end

	local pixels = screen:render(function(d)
		d:setOrtho()
		d:clearLighting()
		d:clearTexture()
		d:setColor(0, 0, 0, 1)
		d:rect(0, 0, W, H)
		d:setColor(1, 1, 1, 1)
		d:mesh(quad(layer * 3 + 1), 50, 50, 0)
	end)

	---@param x number
	---@return number
	local function brightness(x)
		local r, g, b = pixels(x, 55)
		return (r + g + b) / 3
	end

	-- u runs 0 to 2 over the quad, so x = 51, 54 and 56 are a quarter, three quarters
	-- and one and a quarter of the way across it
	test.less(brightness(51), 60)
	test.greater(brightness(54), 190)
	test.less(brightness(56), 60)
end)

screenIt("render: a merged face does not show a seam where its tile wraps", function()
	-- safety: a face two blocks wide repeats its tile in the middle of the quad, and a
	-- sample on that wrap lands on the texel next to the image, which belongs to the
	-- layer and is transparent, so the join would show as a see-through line
	local texels = ffi.new("uint8_t[16 * 48 * 4]")
	for i = 0, 16 * 48 - 1 do
		texels[i * 4], texels[i * 4 + 1], texels[i * 4 + 2], texels[i * 4 + 3] = 255, 255, 255, 255
	end

	local draw = screen.draw
	local layer = draw:addTexture(16, 48, texels)

	-- two blocks across, so the tile wraps down the middle of the quad
	local mesh = Assets.new(draw):mesh({
		0, 0, 0, 0, 0, 1, 0, 1, layer * 3 + 1,
		40, 0, 0, 0, 0, 1, 2, 1, layer * 3 + 1,
		40, 40, 0, 0, 0, 1, 2, 0, layer * 3 + 1,
		0, 40, 0, 0, 0, 1, 0, 0, layer * 3 + 1,
	}, { 0, 1, 2, 0, 2, 3 }, 9)

	local pixels = screen:render(function(d)
		d:setOrtho()
		d:clearLighting()
		d:clearTexture()
		d:setColor(0, 0, 0, 1)
		d:rect(0, 0, W, H)
		d:setColor(1, 1, 1, 1)
		d:mesh(mesh, 100, 100, 0)
	end)

	-- the join is at x = 120, and the tile is white everywhere, so every pixel of the
	-- face has to be white
	for x = 110, 130 do
		expectAt(pixels, "across the tile wrap", x, 120, 1, 1, 1)
	end
end)

screenIt("render: a face drawn from a smaller level keeps to its own tile", function()
	-- safety: half a texel of inset only holds a sample inside its tile while the level
	-- it comes from is filtered over no more than that, and a face far enough away is
	-- filtered over a whole footprint of them. Reaching that far takes in the tile of
	-- the face stacked next to it in the image, which draws a seam between every pair of
	-- blocks in the world once they are far enough to be sampled from a smaller level
	local texels = ffi.new("uint8_t[?]", 32 * 96 * 4)
	for y = 0, 95 do
		for x = 0, 31 do
			local at = (y * 32 + x) * 4
			local drawn = math.floor(y / 32) == 1
			texels[at], texels[at + 1], texels[at + 2], texels[at + 3] =
				drawn and 128 or 255, drawn and 128 or 0, drawn and 128 or 0, 255
		end
	end

	local draw = screen.draw
	local layer = draw:addTexture(32, 96, texels)

	-- eight blocks across and tall, so the tile wraps at every block boundary
	local mesh = Assets.new(draw):mesh({
		-4, 0, 0, 0, 0, 1, 0, 8, layer * 3 + 1,
		4, 0, 0, 0, 0, 1, 8, 8, layer * 3 + 1,
		4, 8, 0, 0, 0, 1, 8, 0, layer * 3 + 1,
		-4, 8, 0, 0, 0, 1, 0, 0, layer * 3 + 1,
	}, { 0, 1, 2, 0, 2, 3 }, 9)

	local pixels = screen:render(function(d)
		d:setCamera({
			position = { 0, 4, 45 },
			target = { 0, 4, 0 },
			fov = math.pi / 3,
			near = 0.1,
			far = 400,
		})

		-- safety: ambient white and no lights at all, so what is drawn is the texture
		-- itself and nothing about the lighting can be mistaken for a seam
		d:setLighting({ ambient = { 1, 1, 1 }, lights = {} })
		d:setColor(1, 1, 1, 1)
		d:clearTexture()
		d:mesh(mesh, 0, 0, 0)
	end)

	-- the face is grey everywhere it was painted, so no pixel of it may lean towards the
	-- red of the tiles above and below the one it repeats
	local worst = 0
	for y = 0, H - 1 do
		for x = 0, W - 1 do
			local r, g = pixels(x, y)
			if g > 40 then
				worst = math.max(worst, r)
			end
		end
	end

	test.less(worst, 140)
end)

screenIt("render: a point light is brightest under it and fades with distance", function()
	-- safety: the 2D view maps a unit to a pixel with the origin in the bottom left,
	-- so a light placed in screen space sits a known distance from the pixels it
	-- lights: this one hangs 60 units off the middle of the frame
	local pixels = screen:render(function(d)
		d:setOrtho()
		d:setLighting({
			ambient = { 0, 0, 0 },
			lights = { { pos = { 200, 150, 60 }, radius = 400, color = { 1, 1, 1 } } },
		})
		d:setColor(1, 1, 1, 1)
		d:clearTexture()
		d:rect(0, 0, W, H)
	end)

	---@param x number
	---@return number
	local function brightness(x)
		local r, g, b = pixels(x, 150)
		return (r + g + b) / 3
	end

	local under = brightness(200)
	local beside = brightness(300)

	test.greater(under, 150)
	test.greater(beside, 40)
	test.less(beside, under)
end)

screenIt("render: a point light stops at its radius", function()
	---@param lightRadius number
	---@return tests.Pixels
	local function scene(lightRadius)
		return screen:render(function(d)
			d:setOrtho()
			d:setLighting({
				ambient = { 0, 0, 0 },
				lights = { { pos = { 200, 150, 60 }, radius = lightRadius, color = { 1, 1, 1 } } },
			})
			d:setColor(1, 1, 1, 1)
			d:clearTexture()
			d:rect(0, 0, W, H)
		end)
	end

	-- the rect is at z = 0, so that pixel is 208 units from the light: inside a
	-- radius of 400 and well outside one of 100
	local wide = scene(400)
	local narrow = scene(100)

	test.greater(wide(399, 150), 8)
	expectAt(narrow, "past the edge of the light", 399, 150, 0, 0, 0)
end)

screenIt("render: a frame with no lights is lit by its ambient alone", function()
	local pixels = screen:render(function(d)
		d:setOrtho()
		d:setLighting({ ambient = { 0.5, 0.5, 0.5 } })
		d:setColor(1, 1, 1, 1)
		d:clearTexture()
		d:rect(0, 0, W, H)
	end)

	expectAt(pixels, "half the color it was drawn with", 100, 100, 0.5, 0.5, 0.5)
end)

screenIt("render: clearLighting leaves what is drawn alone", function()
	local pixels = screen:render(function(d)
		d:setOrtho()
		d:clearLighting()
		d:setColor(0.25, 0.5, 0.75, 1)
		d:clearTexture()
		d:rect(0, 0, W, H)
	end)

	expectAt(pixels, "the color it was drawn with", 100, 100, 0.25, 0.5, 0.75)
end)

screenIt("render: a light without a direction or a position is refused", function()
	screen:frame(function(d)
		d:setOrtho()

		-- safety: the light that is refused is deliberately the wrong shape, so it is
		-- written as a plain value rather than a lighting table the checker can see
		---@type any
		local directionless = { color = { 1, 1, 1 } }

		test.errors(function()
			d:setLighting({ lights = { directionless } })
		end, "lupa: a light needs a dir, or a pos and a radius")

		test.errors(function()
			local lights = {}
			for index = 1, 9 do
				lights[index] = { dir = { 0, -1, 0 } }
			end
			d:setLighting({ lights = lights })
		end, "lupa: at most 8 lights in a frame, got 9")
	end)
end)

screenIt("render: the first light asking for shadows casts, and it has to be directional", function()
	screen:frame(function(d)
		d:setOrtho()
		d:setLighting({
			lights = {
				{ dir = { 0, -1, 0 }, shadows = { distance = 96, cascades = 2 } },
				{ dir = { 1, 0, 0 }, shadows = { distance = 64, cascades = 4 } },
			},
		})
	end)

	test.equal(screen.draw.lighting.shadowLight, 0)
	test.equal(screen.draw.lighting.shadowEnabled, 1)
	test.truthy(screen.draw.shadowEnabled)
	test.equal(screen.draw.shadowDistance, 96)
	test.equal(screen.draw.shadowCascades, 2)

	-- safety: only a directional light has a map to render from one place, so a point
	-- light asking for shadows is skipped rather than casting from nowhere
	screen:frame(function(d)
		d:setOrtho()
		d:setLighting({
			lights = {
				{ pos = { 0, 4, 0 }, radius = 8, shadows = true },
				{ dir = { 1, 0, 0 }, shadows = { distance = 64 } },
			},
		})
	end)

	test.equal(screen.draw.lighting.shadowLight, 1)
	test.equal(screen.draw.shadowDistance, 64)
	test.equal(screen.draw.shadowCascades, 4)

	test.errors(function()
		screen:frame(function(d)
			d:setOrtho()
			d:setLighting({ lights = { { dir = { 0, -1, 0 }, shadows = { cascades = 5 } } } })
		end)
	end, "lupa: shadows take 1 to 4 cascades, got 5")

	test.errors(function()
		screen:frame(function(d)
			d:setOrtho()
			d:setLighting({ lights = { { dir = { 0, -1, 0 }, shadows = { cascades = 0 } } } })
		end)
	end, "lupa: shadows take 1 to 4 cascades, got 0")
end)

screenIt("render: a cascade covers the view it was fitted to, and the next one reaches further", function()
	screen:frame(function(d)
		d:setCamera({ position = { 0, 4, 8 }, target = { 0, 0, 0 }, fov = math.pi / 3, near = 0.1, far = 400 })
		d:setLighting({
			lights = { { dir = { 0.4, -1, 0.3 }, shadows = { distance = 96, cascades = 4 } } },
		})
	end)

	-- safety: the cascades are fitted once the frame's camera and the size of its
	-- target are both known, so what covers what is there after the frame, not after
	-- setLighting
	local lighting = screen.draw.lighting
	local splits, texels = {}, {}
	for index = 0, 3 do
		splits[index + 1] = lighting.shadowSplits[index]
		texels[index + 1] = lighting.shadowTexels[index]
	end

	-- the last split is the shadow distance, and each is further than the one before
	test.equal(splits[4], 96)
	for index = 2, 4 do
		test.greater(splits[index], splits[index - 1])
	end

	-- each cascade looks through a wider box than the one before it, so one of its
	-- texels covers more of the world
	for index = 2, 4 do
		test.greater(texels[index], texels[index - 1])
	end

	test.greater(texels[1], 0)
end)

screenIt("render: the nearest cascade is sharper than a single box over the whole view", function()
	screen:frame(function(d)
		d:setCamera({ position = { 0, 4, 8 }, target = { 0, 0, 0 }, fov = math.pi / 3, near = 0.1, far = 400 })
		d:setLighting({
			lights = { { dir = { 0.4, -1, 0.3 }, shadows = { distance = 128, cascades = 4 } } },
		})
	end)

	-- one box over the same distance would cover 128 units either side of the camera
	-- with the game's map of 1024, which is a texel per eighth of a block
	test.less(screen.draw.lighting.shadowTexels[0], 128 * 2 / 1024 / 4)
end)

screenIt("render: endShadowCasters can give each cascade its own share of the casters", function()
	screen:frame(function(d)
		d:setOrtho()
		d:setLighting({ lights = { { dir = { 0, -1, 0 }, shadows = true } } })
		d:clearTexture()

		-- safety: two textures rather than two colors, because records of the same
		-- mesh and texture are drawn as one instanced command
		for index = 1, 3 do
			d:setTexture(uploadTexels(d))
			d:cube(index * 2, 0, 0, 1)
		end

		d:endShadowCasters({ 1, 2, 3, 999 })
	end)

	test.equal(screen.draw.shadowRecords, 3)
	test.equal(screen.draw.casterCounts[1], 1)
	test.equal(screen.draw.casterCounts[2], 2)
	test.equal(screen.draw.casterCounts[3], 3)
	-- a share larger than the list is the whole list
	test.equal(screen.draw.casterCounts[4], 3)

	-- safety: the counts that are refused are deliberately not numbers, so they are
	-- written as a plain value rather than a table the checker can see
	---@type any
	local wrong = { "one" }

	test.errors(function()
		screen:frame(function(d)
			d:setOrtho()
			d:setLighting({ lights = { { dir = { 0, -1, 0 }, shadows = true } } })
			d:cube(0, 0, 0, 1)
			d:endShadowCasters(wrong)
		end)
	end, "lupa: endShadowCasters wants how many records cascade 1 draws")
end)

screenIt("render: a cascade that is given no casters leaves what it covers lit", function()
	---@param counts number[]?
	---@return tests.Pixels
	local function scene(counts)
		return screen:render(function(d)
			d:setOrtho()
			d:setCamera({ position = { 0, 3, 10 }, target = { 0, 0, 0 }, up = { 0, 1, 0 } })
			d:setLighting({
				ambient = { 0.15, 0.15, 0.15 },
				lights = { { dir = { 0.3, -1, 0.4 }, color = { 0.6, 0.6, 0.6 }, shadows = true } },
			})
			d:setColor(1, 1, 1, 1)
			d:clearTexture()
			d:plane(0, 0, 0, 40, 40)
			d:cube(0, 1, 0, 2)
			d:endShadowCasters(counts)
		end)
	end

	local casting = scene(nil)
	local none = scene({ 0, 0, 0, 0 })

	---@param pixels tests.Pixels
	---@param x number
	---@param y number
	---@return number
	local function brightness(pixels, x, y)
		local r, g, b = pixels(x, y)
		return (r + g + b) / 3
	end

	-- somewhere the cube's shadow falls: dark with the cube in the map, lit without
	local dark = 0
	for y = 100, 200 do
		for x = 150, 250 do
			--
			local value = brightness(casting, x, y)
			if value < brightness(none, x, y) - 20 then
				dark = dark + 1
			end
		end
	end

	test.greater(dark, 100)
end)

screenIt("render: a texture smaller on screen than its image is drawn from a smaller level of it", function()
	-- safety: a 64x64 checker drawn eight pixels wide has to come out as the average of
	-- it. Sampling the largest level alone would land on one square of the checker or
	-- the other, whichever the pixel happened to fall in
	local size = 64
	local texels = ffi.new("uint8_t[?]", size * size * 4)
	for y = 0, size - 1 do
		for x = 0, size - 1 do
			local index = (y * size + x) * 4
			local on = (x + y) % 2 == 0
			texels[index] = on and 255 or 0
			texels[index + 1] = on and 255 or 0
			texels[index + 2] = on and 255 or 0
			texels[index + 3] = 255
		end
	end

	local pixels = screen:render(function(d)
		d:setOrtho()
		d:clearLighting()
		d:setColor(0, 0, 0, 1)
		d:clearTexture()
		d:rect(0, 0, W, H)

		d:setColor(1, 1, 1, 1)
		d:setTexture(d:addTexture(size, size, texels))
		d:rect(0, 0, 8, 8)
	end)

	-- the middle of the rect, away from its edges where the level above still shows
	for _, point in ipairs({ { 3, 3 }, { 4, 4 }, { 5, 5 } }) do
		local r = pixels(point[1], point[2])
		test.greater(r, 60)
		test.less(r, 190)
	end
end)

screenIt("render: a texture that emits shows in a frame with no light in it", function()
	local texels = ffi.new("uint8_t[16]", {
		255, 255, 255, 255, 255, 255, 255, 255,
		255, 255, 255, 255, 255, 255, 255, 255,
	})

	local plain = screen:render(function(d)
		d:setOrtho()
		d:setLighting({ ambient = { 0, 0, 0 } })
		d:setColor(1, 1, 1, 1)
		d:setTexture(d:addTexture(2, 2, texels))
		d:rect(0, 0, W, H)
	end)

	local glowing = screen:render(function(d)
		d:setOrtho()
		d:setLighting({ ambient = { 0, 0, 0 } })
		d:setColor(1, 1, 1, 1)
		d:setTexture(d:addTexture(2, 2, texels, { emission = 0.5 }))
		d:rect(0, 0, W, H)
	end)

	expectAt(plain, "a texture lit by nothing", 100, 100, 0, 0, 0)
	expectAt(glowing, "a texture that emits half of itself", 100, 100, 0.5, 0.5, 0.5)
end)

screenIt("render: a cut out texture leaves the half clear texels undrawn", function()
	local texels = ffi.new("uint8_t[16]", {
		255, 0, 0, 255, 255, 255, 255, 100,
		255, 0, 0, 255, 255, 255, 255, 100,
	})

	---@param cutout boolean
	---@return tests.Pixels
	local function scene(cutout)
		return screen:render(function(d)
			d:setOrtho()
			d:clearLighting()
			d:setColor(1, 0, 0, 1)
			d:clearTexture()
			d:rect(0, 0, W, H)

			d:setColor(1, 1, 1, 1)
			d:setTexture(d:addTexture(2, 2, texels, { cutout = cutout }))
			d:rect(0, 0, W, H)
		end)
	end

	-- safety: the left column of the texture is opaque red and the right one is more
	-- clear than not, and the samples sit on the middle of each column, where a bilinear
	-- sample is the texel itself rather than a mix of the two
	expectAt(scene(true), "the middle of the clear column, cut out", 300, 100, 1, 0, 0)
	expectAt(scene(true), "the middle of the opaque column, cut out", 100, 100, 1, 0, 0)
	expectAt(scene(false), "the middle of the clear column, blended", 300, 100, 1, 100 / 255, 100 / 255)
end)

screenIt("render: the far end of the view fades into the fog", function()
	---@param far number how far away the fade is complete, 0 for none
	---@return tests.Pixels
	local function scene(far)
		return screen:render(function(d)
			d:setOrtho()
			d:setCamera({ position = { 0, 10, 20 }, target = { 0, 0, -60 }, fov = math.pi / 3, near = 0.1, far = 400 })
			d:setLighting({
				ambient = { 1, 1, 1 },
				fog = { color = { 0, 0, 1 }, near = far * 0.25, far = far },
				lights = { { dir = { 0, -1, 0 } } },
			})
			d:setColor(1, 0, 0, 1)
			d:clearTexture()
			d:plane(0, 0, 0, 400, 400)
		end)
	end

	-- safety: the ground runs away from the camera, so the bottom of the frame is under
	-- it and the horizon is far down it, and only the far end takes the colour of the fog
	local plain = scene(0)
	local fogged = scene(80)

	expectAt(fogged, "the ground under the camera", 200, 20, 1, 0, 0)

	local _, _, plainBlue = plain(200, 150)
	local _, _, fogBlue = fogged(200, 150)

	test.less(plainBlue, 40)
	test.greater(fogBlue, 200)
end)

screenIt("render: a smaller level of a tiled texture keeps each tile to itself", function()
	-- safety: the two rows are one block's top and side, and the level below the largest
	-- one is filtered within a row: a level that averaged across the join would make the
	-- top of a far away block take the colour of its sides
	local size = 64
	local texels = ffi.new("uint8_t[?]", size * size * 4)
	for y = 0, size - 1 do
		for x = 0, size - 1 do
			local index = (y * size + x) * 4
			local white = y < size / 2
			texels[index] = white and 255 or 0
			texels[index + 1] = white and 255 or 0
			texels[index + 2] = white and 255 or 0
			texels[index + 3] = 255
		end
	end

	local pixels = screen:render(function(d)
		d:setOrtho()
		d:clearLighting()
		d:setColor(0, 0, 0, 1)
		d:clearTexture()
		d:rect(0, 0, W, H)

		-- one texel of the top row, drawn small enough that the level below is sampled
		d:setColor(1, 1, 1, 1)
		d:setTexture(d:addTexture(size, size, texels, { rows = 2 }))
		d:setTextureRect(0, 0, 0.125, 0.5)
		d:rect(0, 0, 8, 8)
		d:setTextureRect(0, 0, 1, 1)
	end)

	for _, point in ipairs({ { 3, 4 }, { 4, 4 }, { 5, 4 } }) do
		local r = pixels(point[1], point[2])
		test.greater(r, 180)
	end
end)

screenIt("render: a mesh keeps detail far smaller than the world it is drawn in", function()
	local assets = Assets.new(screen.draw)

	-- safety: a vertex is stored as an integer of the mesh's own size, so a mesh a
	-- thousandth of a unit across has to keep a difference a thousandth of that. A
	-- format with a fixed unit would have collapsed this triangle onto one pixel
	local sliver = assets:mesh({
		0, 0, 0, 0, 0, 1, 0, 0,
		0.001, 0, 0, 0, 0, 1, 1, 0,
		0, 0.001, 0, 0, 0, 1, 0, 1,
	}, { 0, 1, 2 })

	local pixels = screen:render(function(d)
		d:setOrtho()
		d:clearLighting()
		d:setColor(0, 0, 0, 1)
		d:clearTexture()
		d:rect(0, 0, W, H)

		d:setColor(1, 1, 1, 1)
		d:pushModel()
		d:scale(200000)
		d:mesh(sliver, 0, 0, 0)
		d:popModel()
	end)

	-- the triangle is 200 pixels across and 200 tall, so its first column is drawn and
	-- the far side of the square it sits in is not
	test.greater(pixels(2, 2), 200)
	test.less(pixels(120, 120), 40)
end)

screenIt("render: a mesh of one point or none at all is drawn without a size of its own", function()
	local assets = Assets.new(screen.draw)

	local one = assets:mesh({ 0, 0, 0, 0, 0, 1, 0, 0 }, { 0, 0, 0 })
	local none = assets:mesh({}, nil)

	screen:frame(function(d)
		d:setOrtho()
		d:clearLighting()
		d:setColor(1, 1, 1, 1)
		d:clearTexture()
		d:mesh(one, 10, 10, 0)
		d:mesh(none, 20, 20, 0)
	end)
end)
