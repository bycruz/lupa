---@alias lupa.Input.Key
---| "backspace"
---| "enter"
---| "tab"
---| "shift"
---| "ctrl"
---| "alt"
---| string

---@class lupa.InputModifiers
---@field shift boolean
---@field ctrl boolean
---@field alt boolean

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

-- safety: X11-style button numbers, which is what winit reports
local BUTTON_NAMES = { left = 1, middle = 2, right = 3 }

-- safety: a modifier arrives as the key that carries it, so "ctrl" has to be answered
-- for either of the two
---@type table<string, string[]>
local MODIFIER_KEYS = {
	shift = { "left-shift", "right-shift" },
	ctrl = { "left-ctrl", "right-ctrl" },
	alt = { "left-alt", "right-alt" },
}

--- The modifier a key stands for, which is how a key event decides its own modifier.
---@type table<string, string>
local MODIFIER_OF = {}
for name, keys in pairs(MODIFIER_KEYS) do
	for index = 1, #keys do
		MODIFIER_OF[keys[index]] = name
	end
end

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
---@field private modifierState lupa.InputModifiers
---@field private typed string what the keys pressed this frame typed
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

		typed = "",
		mouseX = 0, mouseY = 0,
		motionX = 0, motionY = 0,
		scrollX = 0, scrollY = 0,
		modifierState = { shift = false, ctrl = false, alt = false },

		window = window,
	}, Input)
end

--- Whether one of the keys a name stands for is in a table of them, which for a key
--- that is not a modifier name is that key alone.
---@type fun(keys: table<string, boolean>, key: string): boolean
local function anyOf(keys, key)
	local names = MODIFIER_KEYS[key]
	if not names then
		return keys[key] == true
	end

	for index = 1, #names do
		if keys[names[index]] then
			return true
		end
	end

	return false
end

--- Leave the modifier state as one key event leaves it.
---
--- safety: the modifiers a backend reports belong to the event rather than to the state
--- after it: a key release carries the modifiers as they were just before it, so letting
--- go of shift arrives with shift still set, and taking that as the state leaves shift
--- held down until some other key is pressed. The key the event is about is what decides
--- its own modifier here, whichever way round the backend reports it.
---@type fun(state: lupa.InputModifiers, key: lupa.Input.Key, modifiers: lupa.InputModifiers?, down: boolean)
local function rememberModifiers(state, key, modifiers, down)
	if modifiers then
		state.shift = modifiers.shift == true
		state.ctrl = modifiers.ctrl == true
		state.alt = modifiers.alt == true
	end

	local name = MODIFIER_OF[key]
	if name == "shift" then
		state.shift = down
	elseif name == "ctrl" then
		state.ctrl = down
	elseif name == "alt" then
		state.alt = down
	end
end

---@type fun(self: lupa.Input, key: lupa.Input.Key): boolean
function Input:isHeld(key)
	return anyOf(self.held, key)
end

---@type fun(self: lupa.Input, key: lupa.Input.Key): boolean
function Input:wasPressed(key)
	return anyOf(self.pressed, key)
end

---@type fun(self: lupa.Input, key: lupa.Input.Key): boolean
function Input:wasReleased(key)
	return anyOf(self.released, key)
end

-- safety: a key event is the only place modifiers are reported, so this is for a modifier
-- held down while another key is pressed and released
---@type fun(self: lupa.Input): lupa.InputModifiers
function Input:modifiers()
	return self.modifierState
end

--- The text keys typed this frame, which is what a game that reads what a player wrote
--- wants rather than which keys went down.
---@type fun(self: lupa.Input): string
function Input:text()
	return self.typed
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

---@type fun(self: lupa.Input, key: lupa.Input.Key, modifiers: lupa.InputModifiers?, text: string?)
function Input:registerPressed(key, modifiers, text)
	self.held[key] = true
	self.pressed[key] = true

	-- safety: what a key types is kept apart from which key it is, because a letter with
	-- control held is still that letter to a game reading a binding and not the control
	-- character it types, and a letter with shift held is the capital of it to a game
	-- reading what a player wrote. A key that types nothing still reports something --
	-- backspace types its own control character, and tab a tab -- which is text in
	-- neither sense and would be written into whatever a player is writing
	if text and #text > 0 and not text:find("%c") then
		self.typed = self.typed .. text
	end

	rememberModifiers(self.modifierState, key, modifiers, true)
end

---@type fun(self: lupa.Input, key: lupa.Input.Key, modifiers: lupa.InputModifiers?)
function Input:registerReleased(key, modifiers)
	self.held[key] = nil
	self.released[key] = true

	rememberModifiers(self.modifierState, key, modifiers, false)
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
	self.typed = ""
	self.pressed = {}
	self.released = {}
	self.mousePressed = {}
	self.mouseReleased = {}
	self.motionX, self.motionY = 0, 0
	self.scrollX, self.scrollY = 0, 0
end

return Input
