---@alias lupa.Input.Key
---| "backspace"
---| "enter"
---| "tab"
---| "shift"
---| "ctrl"
---| "alt"
---| string

--- Mouse buttons can be named, as an X11-style number (1 = left), or as a
--- winit.button.* constant.
---@alias lupa.Input.MouseButton
---| "left"
---| "right"
---| "middle"
---| integer
---| string

---@alias lupa.Input.CursorGrab
---| "locked"
---| "contain"
---| "none"

--- X11-style button numbers, which is what winit reports.
local BUTTON_NAMES = { left = 1, middle = 2, right = 3 }

---@type fun(button: lupa.Input.MouseButton): any
local function buttonKey(button)
	if type(button) == "number" then
		return button
	end
	return BUTTON_NAMES[button] or button
end

---@class lupa.Input
---@field private window winit.Window?
---@field private held table<lupa.Input.Key, boolean>
---@field private pressed table<lupa.Input.Key, boolean>
---@field private released table<lupa.Input.Key, boolean>
---@field private mouseHeld table<any, boolean>
---@field private mousePressed table<any, boolean>
---@field private mouseReleased table<any, boolean>
---@field private mouseX number
---@field private mouseY number
---@field private motionX number
---@field private motionY number
---@field private scrollX number
---@field private scrollY number
local Input = {}
Input.__index = Input

---@type fun(window: winit.Window?): lupa.Input
function Input.new(window)
	return setmetatable({
		held = {},
		pressed = {},
		released = {},

		mouseHeld = {},
		mousePressed = {},
		mouseReleased = {},

		mouseX = 0, mouseY = 0,
		motionX = 0, motionY = 0,
		scrollX = 0, scrollY = 0,

		window = window,
	}, Input)
end

---@type fun(self: lupa.Input, key: lupa.Input.Key): boolean
function Input:isHeld(key)
	return self.held[key] == true
end

---@type fun(self: lupa.Input, key: lupa.Input.Key): boolean
function Input:wasPressed(key)
	return self.pressed[key] == true
end

---@type fun(self: lupa.Input, key: lupa.Input.Key): boolean
function Input:wasReleased(key)
	return self.released[key] == true
end

---@type fun(self: lupa.Input): number, number
function Input:mousePosition()
	return self.mouseX, self.mouseY
end

---@type fun(self: lupa.Input): number, number
function Input:mouseMotion()
	return self.motionX, self.motionY
end

---@type fun(self: lupa.Input): number, number
function Input:mouseScroll()
	return self.scrollX, self.scrollY
end

---@type fun(self: lupa.Input, button: lupa.Input.MouseButton): boolean
function Input:isMouseHeld(button)
	return self.mouseHeld[buttonKey(button)] == true
end

---@type fun(self: lupa.Input, button: lupa.Input.MouseButton): boolean
function Input:wasMousePressed(button)
	return self.mousePressed[buttonKey(button)] == true
end

---@type fun(self: lupa.Input, button: lupa.Input.MouseButton): boolean
function Input:wasMouseReleased(button)
	return self.mouseReleased[buttonKey(button)] == true
end

---@type fun(self: lupa.Input, mode: lupa.Input.CursorGrab)
function Input:setCursorGrab(mode)
	if self.window then
		self.window:setCursorGrab(mode)
	end
end

---@type fun(self: lupa.Input, key: lupa.Input.Key)
function Input:registerPressed(key)
	self.held[key] = true
	self.pressed[key] = true
end

---@type fun(self: lupa.Input, key: lupa.Input.Key)
function Input:registerReleased(key)
	self.held[key] = nil
	self.released[key] = true
end

---@type fun(self: lupa.Input, x: number, y: number)
function Input:registerMouseMove(x, y)
	self.mouseX, self.mouseY = x, y
end

---@type fun(self: lupa.Input, dx: number, dy: number)
function Input:registerMouseMotion(dx, dy)
	self.motionX = self.motionX + dx
	self.motionY = self.motionY + dy
end

---@type fun(self: lupa.Input, dx: number, dy: number)
function Input:registerMouseScroll(dx, dy)
	self.scrollX = self.scrollX + dx
	self.scrollY = self.scrollY + dy
end

---@type fun(self: lupa.Input, button: lupa.Input.MouseButton)
function Input:registerMousePressed(button)
	local b = buttonKey(button)
	self.mouseHeld[b] = true
	self.mousePressed[b] = true
end

---@type fun(self: lupa.Input, button: lupa.Input.MouseButton)
function Input:registerMouseReleased(button)
	local b = buttonKey(button)
	self.mouseHeld[b] = nil
	self.mouseReleased[b] = true
end

---@type fun(self: lupa.Input)
function Input:clearFrame()
	self.pressed = {}
	self.released = {}
	self.mousePressed = {}
	self.mouseReleased = {}
	self.motionX, self.motionY = 0, 0
	self.scrollX, self.scrollY = 0, 0
end

return Input
