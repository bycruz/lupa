local test = require("lde-test")
local Assets = require("lupa.assets")
local screenFixture = require("tests.fixtures.screen")

local screen, screenError = screenFixture.new(400, 300)
local screenIt = test.skipIf(screen == nil)

if not screen then
	test.skip("scene: skipped, no device available (" .. tostring(screenError) .. ")", function() end)
	return
end

local W, H = screen.width, screen.height
local expectAt = screenFixture.expectAt

--- A camera ten units in front of the origin looking at it. At that distance a
--- world unit is about 26 pixels of the 400x300 target.
---@type fun(d: lupa.Draw)
local function faceOrigin(d)
	d:setCamera({ position = { 0, 0, 10 }, target = { 0, 0, 0 }, up = { 0, 1, 0 } })
end

--- The default 2D view, unlit and untextured.
---@type fun(d: lupa.Draw)
local function flat(d)
	d:setOrtho()
	d:clearLighting()
	d:clearTexture()
end

local quad = Assets.new(screen.draw):mesh({
	-0.5, -0.5, 0, 0, 0, 1, 0, 0,
	 0.5, -0.5, 0, 0, 0, 1, 1, 0,
	 0.5,  0.5, 0, 0, 0, 1, 1, 1,
	-0.5,  0.5, 0, 0, 0, 1, 0, 1,
}, { 0, 1, 2, 0, 2, 3 })

screenIt("scene: the model stack moves a mesh", function()
	local pixels = screen:render(function(d)
		flat(d)
		d:setColor(0, 0, 0, 1)
		d:rect(0, 0, W, H)

		d:setColor(0, 1, 0, 1)
		d:pushModel()
		d:translate(100, 100, 0)
		d:scale(80)
		d:mesh(quad)
		d:popModel()
	end)

	expectAt(pixels, "inside the quad", 100, 100, 0, 1, 0)
	expectAt(pixels, "outside it", 200, 200, 0, 0, 0)
end)

screenIt("scene: popping the model stack undoes the transform", function()
	local pixels = screen:render(function(d)
		flat(d)
		d:setColor(0, 0, 0, 1)
		d:rect(0, 0, W, H)

		d:setColor(0, 1, 1, 1)
		d:pushModel()
		d:translate(300, 200, 0)
		d:scale(80)
		d:mesh(quad)
		d:popModel()

		d:setColor(1, 0, 1, 1)
		d:pushModel()
		d:translate(80, 80, 0)
		d:scale(80)
		d:mesh(quad)
		d:popModel()
	end)

	expectAt(pixels, "the first quad", 300, 200, 0, 1, 1)
	expectAt(pixels, "the second one starts from the origin", 80, 80, 1, 0, 1)
	expectAt(pixels, "and the two do not overlap", 200, 200, 0, 0, 0)
end)

screenIt("scene: a cube in front of the camera covers the middle of the view", function()
	local pixels = screen:render(function(d)
		flat(d)
		faceOrigin(d)

		d:setColor(1, 0.5, 0, 1)
		d:cube(0, 0, 0, 2)
	end)

	expectAt(pixels, "the middle of the cube", math.floor(W / 2), math.floor(H / 2), 1, 0.5, 0)
	expectAt(pixels, "outside it", math.floor(W / 2) + 60, math.floor(H / 2), 0.1, 0.1, 0.1)
end)

screenIt("scene: a sphere is round", function()
	local pixels = screen:render(function(d)
		flat(d)
		faceOrigin(d)

		d:setColor(1, 1, 1, 1)
		d:sphere(0, 0, 0, 1)
	end)

	expectAt(pixels, "the middle of the sphere", math.floor(W / 2), math.floor(H / 2), 1, 1, 1)
	expectAt(pixels, "past its radius", math.floor(W / 2) + 40, math.floor(H / 2), 0.1, 0.1, 0.1)
end)

screenIt("scene: a camera looks down at a plane", function()
	local pixels = screen:render(function(d)
		flat(d)
		d:setCamera({ position = { 0, 5, 0 }, target = { 0, 0, 0 }, up = { 0, 0, -1 } })

		d:setColor(0, 0, 1, 1)
		d:plane(0, 0, 0, 4, 4)
	end)

	-- Five units above a 4x4 plane, the plane covers the middle of the view and
	-- the clear color shows at the sides.
	expectAt(pixels, "the middle of the plane", math.floor(W / 2), math.floor(H / 2), 0, 0, 1)
	expectAt(pixels, "beside it", 20, math.floor(H / 2), 0.1, 0.1, 0.1)
end)

screenIt("scene: an image is sampled in the orientation it was written", function()
	local texture = Assets.new(screen.draw):image("examples/textures/assets/test.png")

	local pixels = screen:render(function(d)
		flat(d)
		d:setColor(1, 1, 1, 1)
		d:setTexture(texture)
		d:rect(0, 0, W, H)
	end)

	-- The image is four quadrants -- red and green over blue and yellow -- with v
	-- running down from the top of the rect.
	local quarterX, quarterY = math.floor(W / 4), math.floor(H / 4)
	expectAt(pixels, "top left, red", quarterX, H - quarterY, 220 / 255, 40 / 255, 40 / 255)
	expectAt(pixels, "top right, green", W - quarterX, H - quarterY, 40 / 255, 200 / 255, 60 / 255)
	expectAt(pixels, "bottom left, blue", quarterX, quarterY, 50 / 255, 80 / 255, 230 / 255)
	expectAt(pixels, "bottom right, yellow", W - quarterX, quarterY, 240 / 255, 210 / 255, 50 / 255)
end)

screenIt("scene: the frame after a camera draws in the 2D view", function()
	screen:frame(function(d)
		flat(d)
		faceOrigin(d)
		d:setColor(1, 0, 0, 1)
		d:cube(0, 0, 0, 4)
	end)

	local pixels = screen:render(function(d)
		flat(d)
		d:setColor(0, 1, 0, 1)
		d:rect(0, 0, W, H)
	end)

	-- safety: the projection is written in place, so a leftover term from the
	-- camera's matrix would leave the 2D frame with nothing in view
	expectAt(pixels, "a corner of the 2D frame", 10, 10, 0, 1, 0)
	expectAt(pixels, "another corner", W - 10, H - 10, 0, 1, 0)
end)

screenIt("scene: a loaded mesh is drawn through the model stack", function()
	local torus = Assets.new(screen.draw):obj("examples/3d/assets/torus.obj")

	local pixels = screen:render(function(d)
		flat(d)
		faceOrigin(d)

		d:setColor(1, 0.5, 0, 1)
		d:pushModel()
		d:rotate(math.pi / 4, 1, 0, 0)
		d:mesh(torus, 0, 0, 0)
		d:popModel()
	end)

	-- The torus spans radius 0.62..1.38, so a point just inside its rim is covered
	-- and the hole in the middle is not.
	expectAt(pixels, "on the rim", math.floor(W / 2) + 26, math.floor(H / 2), 1, 0.5, 0)
	expectAt(pixels, "in the hole", math.floor(W / 2), math.floor(H / 2), 0.1, 0.1, 0.1)
end)

screenIt("scene: a directional light casts a shadow", function()
	-- The camera looks straight down, so world x is screen x and a shadow offset
	-- along the light is visible without any perspective to account for.
	local function scene(shadows)
		return screen:render(function(d)
			flat(d)
			d:setCamera({ position = { 0, 12, 0 }, target = { 0, 0, 0 }, up = { 0, 0, -1 } })
			d:setLighting({ ambient = { 0.05, 0.05, 0.05 }, lights = { { dir = { 1, -1, 0 }, color = { 1, 1, 1 }, shadows = shadows } } })

			d:setColor(1, 1, 1, 1)
			d:plane(0, 0, 0, 20, 20)
			d:cube(0, 1, 0, 2)
		end)
	end

	---@param pixels tests.Pixels
	---@return fun(worldX: number): number
	local function brightnessAt(pixels)
		local perUnit = 150 / (12 * math.tan(math.pi / 6))
		return function(worldX)
			local r, g, b = pixels(math.floor(200 + worldX * perUnit), 150)
			return (r + g + b) / 3
		end
	end

	-- The cube stands at x = 0 and the light leans towards +x, so the plane
	-- behind it is shadowed from x = -1 out to x = 3 and lit away from that.
	local shadowed = brightnessAt(scene(true))
	local lit = brightnessAt(scene(false))

	test.less(shadowed(2.5), 60)
	test.greater(shadowed(-3), 150)
	test.greater(lit(2.5), 150)
end)
