local ffi = require("ffi")
local winit = require("winit")

local Assets = require("lupa.assets")
local Draw = require("lupa.draw")
local Input = require("lupa.input")

---@class lupa.App
---@field start fun(self: lupa.App, assets: lupa.Assets)
---@field update fun(self: lupa.App, dt: number, input: lupa.Input)
---@field draw fun(self: lupa.App, draw: lupa.Draw)
---@field quit fun(self: lupa.App)

---@class lupa
local lupa = {}

ffi.cdef [[
    typedef struct { long tv_sec; long tv_nsec; } LupaTimeSpec;
]]

local CLOCK_MONOTONIC = 1

---@type ffi.ctype* LupaTimeSpec
local timeSpecType = ffi.typeof("LupaTimeSpec")

local timeSpec = timeSpecType()

---@type ffi.ctype* int (*)(int, LupaTimeSpec *), for ffi.cast
local clockGetTime = ffi.cast("int (*)(int, LupaTimeSpec *)", ffi.C.clock_gettime)

--- safety: the wall clock rather than os.clock(), which counts the time the whole process
--- has spent on a CPU, driver threads included
---@type fun(): number
function lupa.now()
	clockGetTime(CLOCK_MONOTONIC, timeSpec)
	return tonumber(timeSpec.tv_sec) + tonumber(timeSpec.tv_nsec) * 1e-9
end

local MAX_DELTA = 0.1

---@class lupa.RunOptions: lupa.DrawOptions
---@field headless boolean? draw without a window
---@field frames number? stop after this many frames; without it a headless run ends when App:quit() is called
---@field width number? size of the window a windowed run opens, defaults to 1200
---@field height number? defaults to 720

---@param app lupa.App
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
	local window = winit.Window.new(eventLoop, options.width or 1200, options.height or 720)
	eventLoop:register(window)

	local draw = Draw.new(window)
	local assets = Assets.new(draw)
	local input = Input.new(window)

	app:start(assets)

	local previous = lupa.now()

	---@type winit.EventHandler
	local function onEvent(event, handler)
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
	end

	eventLoop:run(onEvent)
end

return lupa
