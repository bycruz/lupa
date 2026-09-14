--- 3D demo: orbiting camera, lit ground plane, a ring of spinning cubes and a
--- couple of spheres. Press 1 for the 3D scene, 2 for a 2D scene drawn through
--- the same draw object, escape to quit.
---
--- Note that the projection is per frame: a single frame is either 3D or 2D,
--- because there is one transforms uniform. See the README.
local lupa = require("lupa")

local TAU = math.pi * 2
local cos, sin, floor = math.cos, math.sin, math.floor

---@class Demo3D: lupa.RawApp
local App = {}

local function hsl(h)
	h = (h % 1) * 6
	local i = floor(h)
	local f = h - i
	local x = 1 - math.abs((h % 2) - 1)
	local r, g, b
	if i == 0 then r, g, b = 1, x, 0
	elseif i == 1 then r, g, b = x, 1, 0
	elseif i == 2 then r, g, b = 0, 1, x
	elseif i == 3 then r, g, b = 0, x, 1
	elseif i == 4 then r, g, b = x, 0, 1
	else r, g, b = 1, 0, x end
	-- pastel: pull towards the mid range so the lighting reads well
	return 0.3 + r * 0.55, 0.3 + g * 0.55, 0.3 + b * 0.55
end

function App:start(assets)
	self.time = 0
	self.mode = 1

	-- A mesh loaded from an .obj, drawn alongside the built-in primitives.
	self.torus = assets:obj("assets/torus.obj")

	-- Deterministic ring of cubes, no randomness so runs are reproducible.
	self.cubes = {}
	for i = 1, 64 do
		local a = (i / 64) * TAU
		local ring = 6 + (i % 7)
		self.cubes[i] = {
			x = cos(a) * ring,
			y = -1.2 + (i % 5) * 1.1,
			z = sin(a) * ring,
			size = 0.5 + (i % 4) * 0.22,
			spin = 0.3 + (i % 5) * 0.2,
			hue = i / 64,
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

	if self.mode == 2 then
		-- 2D: the default orthographic view, unlit.
		draw:setOrtho()
		draw:clearLight()

		local W, H = 1200, 720
		local cols, rows = 40, 24
		local cw, ch = W / cols, H / rows
		for row = 0, rows - 1 do
			for col = 0, cols - 1 do
				local v = sin(col * 0.35 + t * 1.6) + cos(row * 0.4 - t * 1.1)
				local r, g, b = hsl((v * 0.25 + 0.5 + t * 0.03) % 1)
				draw:setColor(r, g, b, 1)
				draw:rect(col * cw, row * ch, cw - 1, ch - 1)
			end
		end
		draw:setColor(1, 1, 1, 1)
		draw:rect(W / 2 - 2, H / 2 - 2, 4, 4)
		return
	end

	-- 3D: orbiting camera looking at the origin.
	draw:setCamera({
		position = { x = cos(t * 0.35) * 19, y = 7.5, z = sin(t * 0.35) * 19 },
		target = { x = 0, y = 0, z = 0 },
		fov = math.pi / 3,
		near = 0.1,
		far = 300,
	})

	draw:setLight({
		direction = { x = -0.4, y = -1.0, z = -0.3 },
		color = { 1.0, 0.95, 0.88 },
		ambient = { 0.16, 0.19, 0.28 },
	})

	-- Ground.
	draw:setColor(0.22, 0.25, 0.32, 1)
	draw:plane(0, -2, 0, 90, 90)

	-- Ring of cubes, each with its own model transform on the stack.
	for i, c in ipairs(self.cubes) do
		local r, g, b = hsl(c.hue)
		draw:setColor(r, g, b, 1)

		draw:pushModel()
		draw:translate(c.x, c.y, c.z)
		draw:rotate(t * c.spin, 0, 1, 0)
		draw:cube(0, 0, 0, c.size)
		draw:popModel()
	end

	-- Spheres.
	draw:setColor(0.95, 0.8, 0.3, 1)
	draw:sphere(0, 3.0, 0, 1.7)

	draw:setColor(0.4, 0.85, 0.95, 1)
	draw:sphere(cos(t) * 8, 3.4 + sin(t * 1.3), sin(t) * 8, 0.9)

	-- Loaded mesh: same transform stack, same batching.
	draw:setColor(0.85, 0.4, 0.95, 1)
	draw:pushModel()
	draw:translate(0, 6.5, 0)
	draw:rotate(t * 0.8, 1, 0, 0)
	draw:rotate(t * 0.4, 0, 1, 0)
	draw:mesh(self.torus, 0, 0, 0, 1.6)
	draw:popModel()
end

lupa.run(App)
