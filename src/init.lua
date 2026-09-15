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

		local previous = os.clock()
		local frame = 0

		while running do
			local now = os.clock()
			app:update(now - previous, input)
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

	-- Draw first: Assets uploads images into draw's texture array.
	local draw = Draw.new(window)
	local assets = Assets.new(draw)
	local input = Input.new(window)

	app:start(assets)

	local previous = os.clock()

	eventLoop:run(function(event, handler)
		handler:setMode("poll")

		if not running then
			handler:exit()
		end

		if event.name == "redraw" then
			renderFrame(draw)
		elseif event.name == "aboutToWait" then
			local now = os.clock()
			app:update(now - previous, input)
			previous = now
			input:clearFrame()
			handler:requestRedraw(window)
		elseif event.name == "resize" then
			draw:resize()
		elseif event.name == "keyPress" then
			input:registerPressed(event.key)
		elseif event.name == "keyRelease" then
			input:registerReleased(event.key)
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
