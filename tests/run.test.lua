local test = require("lde-test")
local lupa = require("lupa")

---@param app tests.RunApp
---@param options lupa.RunOptions?
local function run(app, options)
	---@diagnostic disable-next-line: type, assign-type-mismatch
	lupa.run(app, options)
end

---@class tests.RunApp
---@field frames number
---@field drew number
---@field started boolean
---@field lastDt number?
---@field lastInput lupa.Input?
---@field start fun(self: tests.RunApp, assets: lupa.Assets)
---@field update fun(self: tests.RunApp, dt: number, input: lupa.Input)
---@field draw fun(self: tests.RunApp, draw: lupa.Draw)
---@field quit fun(self: tests.RunApp)
local RunApp = {}
RunApp.__index = RunApp

local function newApp()
	local app = setmetatable({ frames = 0, drew = 0, started = false }, RunApp)

---@type fun(self: tests.RunApp, assets: lupa.Assets)
	function app:start(assets)
		self.started = assets ~= nil
	end

---@type fun(self: tests.RunApp, dt: number, input: lupa.Input)
	function app:update(dt, input)
		self.frames = self.frames + 1
		self.lastDt = dt
		self.lastInput = input
	end

---@type fun(self: tests.RunApp, draw: lupa.Draw)
	function app:draw(draw)
		self.drew = self.drew + 1
		draw:setColor(1, 0, 0, 1)
		draw:rect(0, 0, 8, 8)
	end

	return app
end

test.it("run: a headless run draws the frames it was given", function()
	local app = newApp()

	run(app, { headless = true, width = 64, height = 64, frames = 3 })

	test.truthy(app.started)
	test.equal(app.frames, 3)
	test.equal(app.drew, 3)
end)

test.it("run: App:quit ends a headless run before the frame limit", function()
	local app = newApp()

---@type fun(self: tests.RunApp, dt: number, input: lupa.Input)
	function app:update(dt, input)
		self.frames = self.frames + 1
		if self.frames == 2 then
			self:quit()
		end
	end

	run(app, { headless = true, frames = 100 })

	test.equal(app.frames, 2)
end)

test.it("run: every frame is given a non-negative delta", function()
	local app = newApp()
	---@type number[]
	local deltas = {}

---@type fun(self: tests.RunApp, dt: number, input: lupa.Input)
	function app:update(dt, input)
		deltas[#deltas + 1] = dt
	end

	run(app, { headless = true, frames = 3 })

	test.equal(#deltas, 3)
	for i = 1, #deltas do
		test.greaterEqual(deltas[i], 0)
	end
end)

test.it("run: input registered between frames reaches the next one", function()
	local app = newApp()
	local seen = {}

---@type fun(self: tests.RunApp, dt: number, input: lupa.Input)
	function app:update(dt, input)
		self.lastInput = input
		seen[#seen + 1] = input:wasPressed("escape")
	end

---@type fun(self: tests.RunApp, draw: lupa.Draw)
	function app:draw(draw)
		self.drew = self.drew + 1
		if self.drew < 3 then
			assert(self.lastInput):registerPressed("escape")
		end
	end

	run(app, { headless = true, frames = 3 })

	test.equal(#seen, 3)
	test.falsy(seen[1])
	test.truthy(seen[2])
	test.truthy(seen[3])
end)

test.it("run: a missing callback is reported", function()
	test.errors(function()
		run({} --[[@as tests.RunApp]], { headless = true, frames = 1 })
	end, "lupa: App:start(assets) is required")
end)
