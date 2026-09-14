--- Texture demo. Press 1 for 2D sprites, 2 for textured 3D objects, escape to
--- quit.
---
--- The image is 128x128 with a white bar near its top edge, so an upside-down
--- or UV-swapped draw is immediately obvious.
local lupa = require("lupa")
local ffi = require("ffi")

local cos, sin, pi = math.cos, math.sin, math.pi

---@class TextureDemo: lupa.RawApp
local App = {}

function App:start(assets)
	self.time = 0
	self.mode = 1
	self.tex = assets:image("assets/test.png")

	-- A procedurally built texture, to show the raw-pixel path: a 32x32
	-- magenta/black checkerboard.
	local px = ffi.new("uint8_t[?]", 32 * 32 * 4)
	for y = 0, 31 do
		for x = 0, 31 do
			local o = (y * 32 + x) * 4
			local on = (math.floor(x / 8) + math.floor(y / 8)) % 2 == 0
			px[o] = on and 255 or 40
			px[o + 1] = on and 60 or 20
			px[o + 2] = on and 220 or 60
			px[o + 3] = 255
		end
	end
	self.checker = assets:texture(32, 32, px)

	self.cubes = {}
	for i = 1, 24 do
		local a = (i / 24) * pi * 2
		self.cubes[i] = {
			x = cos(a) * 7, y = -1 + (i % 4) * 1.3, z = sin(a) * 7,
			size = 1.2, spin = 0.3 + (i % 3) * 0.25,
		}
	end
end

function App:update(dt, input)
	if input:wasPressed("escape") then self:quit() end
	if input:wasPressed("1") then self.mode = 1 end
	if input:wasPressed("2") then self.mode = 2 end
	self.time = self.time + dt
end

---@param draw lupa.Draw
function App:draw(draw)
	local t = self.time

	if self.mode == 1 then
		draw:setOrtho()
		draw:clearLight()

		-- 2D: one texture, drawn many times. setTexture is state, rect draws.
		draw:setColor(1, 1, 1, 1)
		draw:setTexture(self.tex)
		for row = 0, 3 do
			for col = 0, 3 do
				draw:rect(30 + col * 150, 30 + row * 150, 130, 130)
			end
		end

		-- The procedural checker, stretched and tinted.
		draw:setColor(1, 0.6, 0.9, 1)
		draw:setTexture(self.checker)
		draw:rect(40, 40, 520, 300)

		-- Tiling: the sampled rectangle is allowed to run past the texture, and
		-- the sampler repeats.
		draw:setColor(1, 1, 1, 1)
		draw:setTextureRect(0, 0, 8, 5)
		draw:rect(640, 40, 520, 300)

		-- Sprite sheet: four cells of the same texture in one frame. The
		-- rectangle is per draw call, so this needs no extra state.
		draw:setTexture(self.tex)
		for cell = 0, 3 do
			local cx = cell % 2
			local cy = math.floor(cell / 2)
			draw:setTextureRect(cx * 0.5, cy * 0.5, cx * 0.5 + 0.5, cy * 0.5 + 0.5)
			draw:rect(120 + cell * 240, 400, 200, 200)
		end
		return
	end

	-- 3D: meshes carry their own UVs, and the sampled rectangle remaps them, so
	-- the same image tiles across a plane.
	draw:setCamera({
		position = { x = cos(t * 0.35) * 16, y = 6, z = sin(t * 0.35) * 16 },
		target = { x = 0, y = 0, z = 0 },
		fov = pi / 3, near = 0.1, far = 300,
	})
	draw:setLight({
		direction = { x = -0.4, y = -1.0, z = -0.3 },
		color = { 1.0, 0.95, 0.88 },
		ambient = { 0.25, 0.27, 0.34 },
	})

	draw:setColor(1, 1, 1, 1)
	draw:setTexture(self.checker)
	draw:setTextureRect(0, 0, 30, 30)
	draw:plane(0, -2, 0, 60, 60)

	draw:setTexture(self.tex)
	for _, c in ipairs(self.cubes) do
		draw:pushModel()
		draw:translate(c.x, c.y, c.z)
		draw:rotate(t * c.spin, 0, 1, 0)
		draw:cube(0, 0, 0, c.size)
		draw:popModel()
	end

	draw:sphere(0, 3.5, 0, 1.6)
	draw:clearTexture()
end

lupa.run(App)
