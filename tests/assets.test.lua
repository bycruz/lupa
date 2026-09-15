local test = require("lde-test")
local Assets = require("lupa.assets")
local ffi = require("ffi")
local screenFixture = require("tests.fixtures.screen")

local screen, screenError = screenFixture.new(64, 64)
local screenIt = test.skipIf(screen == nil)

if not screen then
	test.skip("assets: skipped, no device available (" .. tostring(screenError) .. ")", function() end)
	return
end

screenIt("assets: a PNG loads at its own size", function()
	local texture = Assets.new(screen.draw):image("examples/textures/assets/test.png")

	test.equal(texture.width, 128)
	test.equal(texture.height, 128)
end)

screenIt("assets: loading the same image twice reuses its layer", function()
	local assets = Assets.new(screen.draw)
	local first = assets:image("examples/textures/assets/test.png")
	local second = assets:image("examples/textures/assets/test.png")

	test.equal(first.layer, second.layer)
end)

screenIt("assets: a missing image is reported with its path", function()
	local assets = Assets.new(screen.draw)

	test.errors(function()
		assets:image("examples/textures/assets/missing.png")
	end, "lupa: cannot open image 'examples/textures/assets/missing.png'")
end)

screenIt("assets: an image larger than a layer is scaled down to fit", function()
	local pixels = ffi.new("uint8_t[?]", 1024 * 1024 * 4)
	local texture = Assets.new(screen.draw):texture(1024, 1024, pixels)

	test.equal(texture.width, 512)
	test.equal(texture.height, 512)
end)

screenIt("assets: a mesh keeps its vertex and index counts", function()
	local mesh = Assets.new(screen.draw):mesh({
		-1, -1, 0, 0, 0, 1, 0, 0,
		1, -1, 0, 0, 0, 1, 1, 0,
		0, 1, 0, 0, 0, 1, 0.5, 1,
	}, { 0, 1, 2 })

	test.equal(mesh.vertexCount, 3)
	test.equal(mesh.indexCount, 3)
end)

screenIt("assets: vertices that are not 8 floats each are rejected", function()
	local assets = Assets.new(screen.draw)

	test.errors(function()
		assets:mesh({ 0, 0, 0 }, { 0 })
	end, "lupa: mesh vertices must be 8 floats each (x, y, z, nx, ny, nz, u, v); got 3")
end)

screenIt("assets: a Wavefront file loads into triangles", function()
	local mesh = Assets.new(screen.draw):obj("examples/3d/assets/torus.obj")

	test.equal(mesh.vertexCount, 720)
	-- The file's 720 quads fan-triangulate into 1440 triangles.
	test.equal(mesh.indexCount, 4320)
end)
