---@alias lupa.Input.Key
---| "backspace"
---| "enter"
---| "tab"
---| "shift"
---| "ctrl"
---| "alt"
---| string

---@class lupa.Input
---@field private held table<lupa.Input.Key, boolean>
---@field private pressed table<lupa.Input.Key, boolean>
---@field private released table<lupa.Input.Key, boolean>
local Input = {}
Input.__index = Input

function Input.new()
	return setmetatable({ held = {}, pressed = {}, released = {} }, Input)
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

---@private
function Input:clearFrame()
	self.pressed = {}
	self.released = {}
end

return Input
