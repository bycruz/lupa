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

--- Grab modes, matching winit: "locked" hides the pointer and holds it in place
--- (what mouse-look wants), "contain" keeps it inside the window, "none" frees it.
---@alias lupa.Input.CursorGrab
---| "locked"
---| "contain"
---| "none"

-- X11-style button numbers, which is what winit reports.
local BUTTON_NAMES = {
	left = 1,
	middle = 2,
	right = 3,
}

---@param button lupa.Input.MouseButton
---@return integer|any
local function buttonKey(button)
	if type(button) == "number" then
		return button
	end
	return BUTTON_NAMES[button] or button
end

---@class lupa.Input
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
---@field private window winit.Window?
local Input = {}
Input.__index = Input

---@param window winit.Window? required only for setCursorGrab
function Input.new(window)
	local input = setmetatable({
		held = {},
		pressed = {},
		released = {},

		mouseHeld = {},
		mousePressed = {},
		mouseReleased = {},

		mouseX = 0, mouseY = 0,
		motionX = 0, motionY = 0,
		scrollX = 0, scrollY = 0,
	}, Input)

	if type(window) == "table" then
		input.window = window
	end

	return input
end

---@param key lupa.Input.Key
function Input:isHeld(key)
	return self.held[key] == true
end

---@param key lupa.Input.Key
function Input:wasReleased(key)
	return self.released[key] == true
end

---@param key lupa.Input.Key
function Input:wasPressed(key)
	return self.pressed[key] == true
end

---@param key lupa.Input.Key
---@private
function Input:registerPressed(key)
	self.held[key] = true
	self.pressed[key] = true
end

---@param key lupa.Input.Key
---@private
function Input:registerReleased(key)
	self.held[key] = nil
	self.released[key] = true
end

--- Cursor position in window pixels, with y growing downward.
---@return number x, number y
function Input:mousePosition()
	return self.mouseX, self.mouseY
end

--- Raw movement since the last frame, in pixels, straight from the device.
---
--- This is the delta to turn a first-person camera by: it is measured from the
--- pointer hardware, not the cursor, so it keeps working while the cursor is
--- grabbed and it is unaffected by the pointer hitting a screen edge.
---
--- Reading it does not consume it; it accumulates across a frame and is cleared
--- when the frame ends, alongside the pressed/released sets.
---@return number dx, number dy
function Input:mouseMotion()
	return self.motionX, self.motionY
end

--- Scroll wheel movement since the last frame. y is positive scrolling down.
---@return number dx, number dy
function Input:mouseScroll()
	return self.scrollX, self.scrollY
end

---@param button lupa.Input.MouseButton
function Input:isMouseHeld(button)
	return self.mouseHeld[buttonKey(button)] == true
end

---@param button lupa.Input.MouseButton
function Input:wasMousePressed(button)
	return self.mousePressed[buttonKey(button)] == true
end

---@param button lupa.Input.MouseButton
function Input:wasMouseReleased(button)
	return self.mouseReleased[buttonKey(button)] == true
end

--- Hide and hold the pointer, so mouse motion has no screen edges to hit.
---@param mode lupa.Input.CursorGrab
function Input:setCursorGrab(mode)
	if self.window and self.window.setCursorGrab then
		self.window:setCursorGrab(mode)
	end
end

---@param x number
---@param y number
---@private
function Input:registerMouseMove(x, y)
	self.mouseX, self.mouseY = x, y
end

---@param dx number
---@param dy number
---@private
function Input:registerMouseMotion(dx, dy)
	self.motionX = self.motionX + dx
	self.motionY = self.motionY + dy
end

---@param dx number
---@param dy number
---@private
function Input:registerMouseScroll(dx, dy)
	self.scrollX = self.scrollX + dx
	self.scrollY = self.scrollY + dy
end

---@param button lupa.Input.MouseButton
---@private
function Input:registerMousePressed(button)
	local b = buttonKey(button)
	self.mouseHeld[b] = true
	self.mousePressed[b] = true
end

---@param button lupa.Input.MouseButton
---@private
function Input:registerMouseReleased(button)
	local b = buttonKey(button)
	self.mouseHeld[b] = nil
	self.mouseReleased[b] = true
end

---@private
function Input:clearFrame()
	self.pressed = {}
	self.released = {}
	self.mousePressed = {}
	self.mouseReleased = {}
	self.motionX, self.motionY = 0, 0
	self.scrollX, self.scrollY = 0, 0
end

return Input
