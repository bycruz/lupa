local lupa                         = require("lupa")

local W, H                         = 1200, 720
local COLS, ROWS                   = 30, 18
local CW, CH                       = W / COLS, H / ROWS

local sin, sqrt, abs, min, max, pi = math.sin, math.sqrt, math.abs, math.min, math.max, math.pi

-- Plasma always uses s=0.85, l=0.5, so p/q/qp are constants
local Q                            = 0.925
local P                            = 0.075
local QP                           = 0.85

local function hue_channel(t)
	t = t % 1
	if t < 0.16666667 then
		return P + QP * 6 * t
	elseif t < 0.5 then
		return Q
	elseif t < 0.66666667 then
		return P + QP * (0.66666667 - t) * 6
	else
		return P
	end
end

local function hsl_plasma(h)
	h = h % 1
	return hue_channel(h + 0.33333333), hue_channel(h), hue_channel(h - 0.33333333)
end

local function hsl(h, s, l)
	h = h % 1
	if s == 0 then return l, l, l end
	local q = l < 0.5 and l * (1 + s) or l + s - l * s
	local p = 2 * l - q
	local qp = q - p
	local function ch(t)
		t = t % 1
		if t < 0.16666667 then
			return p + qp * 6 * t
		elseif t < 0.5 then
			return q
		elseif t < 0.66666667 then
			return p + qp * (0.66666667 - t) * 6
		else
			return p
		end
	end
	return ch(h + 0.33333333), ch(h), ch(h - 0.33333333)
end

---@type lupa.App<{ time: number, speed: number, mode: number, ball: table }>
local App = {}

function App:start()
	self.time  = 0
	self.speed = 1
	self.mode  = 0
	self.ball  = { x = W / 2, y = H / 2, vx = 220, vy = 160, size = 40 }
end

function App:update(dt, input)
	if input:wasPressed("escape") then self:quit() end

	if input:wasPressed("1") then self.mode = 0 end
	if input:wasPressed("2") then self.mode = 1 end
	if input:wasPressed("3") then self.mode = 2 end

	if input:isHeld("right") then self.speed = min(self.speed + dt * 2, 4) end
	if input:isHeld("left") then self.speed = max(self.speed - dt * 2, 0.1) end

	self.time = self.time + dt * self.speed

	local b = self.ball
	b.x = b.x + b.vx * dt
	b.y = b.y + b.vy * dt
	if b.x < 0 then
		b.x = 0; b.vx = abs(b.vx)
	end
	if b.x + b.size > W then
		b.x = W - b.size; b.vx = -abs(b.vx)
	end
	if b.y < 0 then
		b.y = 0; b.vy = abs(b.vy)
	end
	if b.y + b.size > H then
		b.y = H - b.size; b.vy = -abs(b.vy)
	end
end

function App:draw(draw)
	local t     = self.time
	local mode  = self.mode

	local cols1 = COLS - 1
	local rows1 = ROWS - 1

	if mode == 0 then
		for row = 0, ROWS - 1 do
			local cy = row / rows1
			local sy = sin(cy * pi * 4 + t * 1.2)
			for col = 0, COLS - 1 do
				local cx = col / cols1
				local v = sin(cx * pi * 4 + t * 1.5) + sy + sin((cx + cy) * pi * 3 + t)
				local r, g, b = hsl_plasma((v * 0.33333333 + 1) * 0.5)
				draw:setColor(r, g, b, 1)
				draw:rect(col * CW, row * CH, CW - 1, CH - 1)
			end
		end
	elseif mode == 1 then
		local toff = t * 0.4
		for row = 0, ROWS - 1 do
			local cy = row / rows1
			for col = 0, COLS - 1 do
				local cx = col / cols1
				local r, g, b = hsl_plasma((cx + cy + toff) % 1)
				draw:setColor(r, g, b, 1)
				draw:rect(col * CW, row * CH, CW - 1, CH - 1)
			end
		end
	else
		local toff = t * 0.6
		for row = 0, ROWS - 1 do
			local cy = row / rows1 - 0.5
			local cy2 = cy * cy
			for col = 0, COLS - 1 do
				local cx = col / cols1 - 0.5
				local r, g, b = hsl_plasma((sqrt(cx * cx + cy2) * 2 - toff) % 1)
				draw:setColor(r, g, b, 1)
				draw:rect(col * CW, row * CH, CW - 1, CH - 1)
			end
		end
	end

	-- Mode indicator
	for i = 0, 2 do
		local ir, ig, ib = hsl(i / 3, 0.9, i == mode and 0.75 or 0.25)
		draw:setColor(ir, ig, ib, 1)
		draw:rect(W - 90 + i * 28, H - 20, 20, 12)
	end

	-- Ball
	local b          = self.ball
	local bh         = (t * 0.3) % 1
	local br, bg, bb = hsl(bh, 1, 0.7)

	draw:setColor(br * 0.25, bg * 0.25, bb * 0.25, 1)
	draw:rect(b.x - 14, b.y - 14, b.size + 28, b.size + 28)

	draw:setColor(br * 0.6, bg * 0.6, bb * 0.6, 1)
	draw:rect(b.x - 7, b.y - 7, b.size + 14, b.size + 14)

	draw:setColor(br, bg, bb, 1)
	draw:rect(b.x, b.y, b.size, b.size)

	draw:setColor(1, 1, 1, 1)
	draw:rect(b.x + 8, b.y + 8, b.size * 0.35, b.size * 0.35)
end

lupa.run(App)
