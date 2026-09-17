local ffi = require("ffi")
local winit = require("winit")

local Assets = require("lupa.assets")
local Draw = require("lupa.draw")
local Input = require("lupa.input")

---@class lupa.RawApp<T>
---@field start fun(self: T, assets: lupa.Assets)
---@field update fun(self: T, dt: number, input: lupa.Input)
---@field draw fun(self: T, draw: lupa.Draw)
---@field quit fun(self: T)

---@alias lupa.App<T> lupa.RawApp<T> | T

---@class lupa
local lupa = {}

ffi.cdef [[
    struct timespec { long tv_sec; long tv_nsec; };
    int clock_gettime(int clockid, struct timespec *tp);
]]

local CLOCK_MONOTONIC = 1
local timespec = ffi.new("struct timespec")

--- safety: the wall clock rather than os.clock(), which counts the time the whole process
--- has spent on a CPU, driver threads included
---@type fun(): number
function lupa.now()
	ffi.C.clock_gettime(CLOCK_MONOTONIC, timespec)
	---@diagnostic disable-next-line: undefined-field -- the cdef above declares them
	return tonumber(timespec.tv_sec) + tonumber(timespec.tv_nsec) * 1e-9
end

local MAX_DELTA = 0.1

---@class lupa.RunOptions: lupa.DrawOptions
---@field frames number? stop after this many frames; without it a headless run ends when App:quit() is called

---@generic T
---@param app lupa.App<T>
---@param options lupa.RunOptions?
function lupa.run(app, options)
	options = options or {}

	assert(app.start, "lupa: App:start(assets) is required")
	assert(app.update, "lupa: App:update(dt, input) is required")
	assert(app.draw, "lupa: App:draw(draw) is required")

	local running = true
	function app:quit()
		running = false
	end

---@type fun(draw: lupa.Draw)
	local function renderFrame(draw)
		draw:beginFrame()
		app:draw(draw)
		draw:endFrame()
	end

	if options.headless then
		-- safety: no window and no event loop, so frames are driven here
		local draw = Draw.new(nil, { headless = true, width = options.width, height = options.height })
		local input = Input.new(nil)
		local assets = Assets.new(draw)

		app:start(assets)

		local previous = lupa.now()
		local frame = 0

		while running do
			local now = lupa.now()
			local dt = math.min(now - previous, MAX_DELTA)
			app:update(dt, input)
			previous = now
			input:clearFrame()

			renderFrame(draw)

			frame = frame + 1
			if options.frames and frame >= options.frames then
				running = false
			end
		end

		return
	end

	local eventLoop = winit.EventLoop.new()
	local window = winit.Window.fromEventLoop(eventLoop)

	local draw = Draw.new(window)
	local assets = Assets.new(draw)
	local input = Input.new(window)

	app:start(assets)

	local previous = lupa.now()

	eventLoop:run(function(event, handler)
		handler:setMode("poll")

		if not running then
			handler:exit()
		end

		if event.name == "redraw" then
			renderFrame(draw)
		elseif event.name == "aboutToWait" then
			local now = lupa.now()
			app:update(math.min(now - previous, MAX_DELTA), input)
			previous = now
			input:clearFrame()
			handler:requestRedraw(window)
		elseif event.name == "resize" then
			draw:resize()
		elseif event.name == "keyPress" then
			input:registerPressed(event.key, event.modifiers, event.text)
		elseif event.name == "keyRelease" then
			input:registerReleased(event.key, event.modifiers)
		elseif event.name == "mouseMove" then
			input:registerMouseMove(event.x, event.y)
		elseif event.name == "mouseMotion" then
			input:registerMouseMotion(event.dx, event.dy)
		elseif event.name == "mouseScroll" then
			input:registerMouseScroll(event.dx, event.dy)
		elseif event.name == "mousePress" then
			input:registerMousePressed(event.button)
		elseif event.name == "mouseRelease" then
			input:registerMouseReleased(event.button)
		elseif event.name == "windowClose" then
			handler:exit()
		end
	end)
end

return lupa
