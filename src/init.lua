local winit = require("winit")
local hood = require("hood")

local Assets = require("lupa.assets")
local Draw = require("lupa.draw")
local Input = require("lupa.input")

---@class lupa.RawApp<T>
---! These must be provided by user
---@field start fun(self: T, assets: lupa.Assets)
---@field update fun(self: T, dt: number, input: lupa.Input)
---@field draw fun(self: T, draw: lupa.Draw)
---! These are created by lupa
---@field quit fun(self: T)

--- Sneaky way to actually type the App object while inheriting properties they define
---@alias lupa.App<T> lupa.RawApp<T> | T

---@class lupa
local lupa = {}

---@generic T
---@param app lupa.App<T>
function lupa.run(app)
	local eventLoop = winit.EventLoop.new()
	local window = winit.Window.fromEventLoop(eventLoop)

	assert(app.start, "Missing App:start()")
	assert(app.update, "Missing App:update(dt)")
	assert(app.draw, "Missing App:draw()")

	local isRunning = true
	function app:quit()
		isRunning = false
	end

	-- draw first: Assets uploads images into draw's texture array.
	local draw = Draw.new(window)
	local assets = Assets.new(draw)
	local input = Input.new(window)

	app:start(assets)

	local curtime = os.clock()

	eventLoop:run(function(event, handler)
		handler:setMode("poll")

		if not isRunning then
			handler:exit()
		end

		local now = os.clock()
		local dt = now - curtime
		curtime = now

		if event.name == "redraw" then
			draw:beginFrame()
			app:draw(draw)
			draw:endFrame()
		elseif event.name == "aboutToWait" then
			app:update(dt, input)
			input:clearFrame()
			handler:requestRedraw(window)
		elseif event.name == "resize" then
			-- Rebuild the swapchain and depth target for the new surface size.
			-- Without this the swapchain goes out of date and every frame is
			-- dropped, leaving the window frozen.
			draw:resize()
		elseif event.name == "keyPress" then
			input:registerPressed(event.key)
		elseif event.name == "keyRelease" then
			input:registerReleased(event.key)
		elseif event.name == "mouseMove" then
			input:registerMouseMove(event.x, event.y)
		elseif event.name == "mouseMotion" then
			-- Raw device deltas, which is what a first-person camera turns by.
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
