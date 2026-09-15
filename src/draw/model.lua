local lpmath = require("lupa.math")
local limits = require("lupa.draw.limits")

--- The model matrix stack, preallocated so push and pop never allocate.
---@class lupa.draw.Model
---@field resetModel fun(self: lupa.Draw)
---@field pushModel fun(self: lupa.Draw)
---@field popModel fun(self: lupa.Draw)
---@field translate fun(self: lupa.Draw, x: number, y: number, z: number)
---@field scale fun(self: lupa.Draw, x: number, y: number?, z: number?)
---@field rotate fun(self: lupa.Draw, angle: number, x: number, y: number, z: number)
local model = {}

---@return lupa.math.Mat4[] stack
---@return lupa.math.Mat4 scratch
function model.newStack()
	local stack = {}
	for i = 1, limits.modelStack do
		stack[i] = lpmath.mat4.identity()
	end
	return stack, lpmath.mat4.identity()
end

local methods = {}

--- Reset the stack to a single identity matrix.
---@type fun(self: lupa.Draw)
function methods.resetModel(self)
	local e = self.modelStack[1].m
	e[0], e[1], e[2], e[3] = 1, 0, 0, 0
	e[4], e[5], e[6], e[7] = 0, 1, 0, 0
	e[8], e[9], e[10], e[11] = 0, 0, 1, 0
	e[12], e[13], e[14], e[15] = 0, 0, 0, 1

	self.modelDepth = 1
	self.model = self.modelStack[1]
end

--- Save the current transform and start a nested one.
---@type fun(self: lupa.Draw)
function methods.pushModel(self)
	local depth = self.modelDepth + 1
	if depth > limits.modelStack then
		error("lupa: model matrix stack overflow (max " .. limits.modelStack .. ")")
	end

	local dst, src = self.modelStack[depth].m, self.modelStack[depth - 1].m
	for i = 0, 15 do
		dst[i] = src[i]
	end

	self.modelDepth = depth
	self.model = self.modelStack[depth]
end

--- Restore the transform saved by the matching pushModel.
---@type fun(self: lupa.Draw)
function methods.popModel(self)
	local depth = self.modelDepth
	if depth <= 1 then
		return
	end

	self.modelDepth = depth - 1
	self.model = self.modelStack[depth - 1]
end

---@type fun(self: lupa.Draw, x: number, y: number, z: number)
function methods.translate(self, x, y, z)
	local e = self.model.m
	e[12] = e[0] * x + e[4] * y + e[8] * z + e[12]
	e[13] = e[1] * x + e[5] * y + e[9] * z + e[13]
	e[14] = e[2] * x + e[6] * y + e[10] * z + e[14]
	e[15] = e[3] * x + e[7] * y + e[11] * z + e[15]
end

---@type fun(self: lupa.Draw, x: number, y: number?, z: number?)
function methods.scale(self, x, y, z)
	y = y or x
	z = z or x
	local e = self.model.m
	e[0], e[1], e[2], e[3] = e[0] * x, e[1] * x, e[2] * x, e[3] * x
	e[4], e[5], e[6], e[7] = e[4] * y, e[5] * y, e[6] * y, e[7] * y
	e[8], e[9], e[10], e[11] = e[8] * z, e[9] * z, e[10] * z, e[11] * z
end

--- Rotate about an axis, which defaults to +Y.
---@type fun(self: lupa.Draw, angle: number, x: number?, y: number?, z: number?)
function methods.rotate(self, angle, x, y, z)
	if x == nil and y == nil and z == nil then
		x, y, z = 0, 1, 0
	end

	lpmath.mat4.rotateInto(self.rotationScratch, angle, x or 0, y or 0, z or 0)
	lpmath.mat4.mulInto(self.model, self.model, self.rotationScratch)
end

model.methods = methods

return model
