local lpmath = require("lupa.math")
local records = require("lupa.draw.records")

--- Scratch, so moving the camera every frame allocates nothing.
local eye = lpmath.vec3.new(0, 0, 0)
local target = lpmath.vec3.new(0, 0, 0)
local up = lpmath.vec3.new(0, 1, 0)
local viewMatrix = lpmath.mat4.identity()
local projMatrix = lpmath.mat4.identity()

---@alias lupa.draw.XYZ { x: number, y: number, z: number } | number[]

---@class lupa.draw.Camera
---@field position lupa.draw.XYZ
---@field target lupa.draw.XYZ? defaults to the origin
---@field up lupa.draw.XYZ? defaults to +Y
---@field fov number? radians, defaults to pi/3
---@field near number? defaults to 0.1
---@field far number? defaults to 1000

---@class lupa.draw.Light
---@field direction lupa.draw.XYZ the direction the light travels in
---@field color lupa.draw.XYZ? defaults to white
---@field ambient lupa.draw.XYZ? defaults to 0.2 grey

--- The camera, the projection and the lighting.
---@class lupa.draw.View
---@field setCamera fun(self: lupa.Draw, t: lupa.draw.Camera)
---@field setViewProjection fun(self: lupa.Draw, m: lupa.math.Mat4)
---@field setOrtho fun(self: lupa.Draw)
---@field setLight fun(self: lupa.Draw, t: lupa.draw.Light)
---@field clearLight fun(self: lupa.Draw)
local view = {}

function view.newState()
	return records.newTransforms(), records.newLighting()
end

--- Accept {x =, y =, z =} or {x, y, z}, falling back per component.
---@type fun(t: table|nil, dx: number, dy: number, dz: number): number, number, number
local function xyz(t, dx, dy, dz)
	if type(t) ~= "table" then
		return dx, dy, dz
	end
	return t.x or t[1] or dx, t.y or t[2] or dy, t.z or t[3] or dz
end

---@type fun(v: lupa.math.Vec3, t: table|nil, dx: number, dy: number, dz: number)
local function setVec3(v, t, dx, dy, dz)
	local x, y, z = xyz(t, dx, dy, dz)
	v.x, v.y, v.z = x, y, z
end

--- The projection of the frame, rebuilt when the target size changes.
---@type fun(draw: lupa.Draw, width: number, height: number)
function view.refreshProjection(draw, width, height)
	if draw.customView or (draw.projWidth == width and draw.projHeight == height) then
		return
	end

	draw.projWidth, draw.projHeight = width, height
	lpmath.mat4.orthoInto(draw.transforms.viewProj, 0, width, 0, height, -1, 1)
end

local methods = {}

--- Point a perspective camera at a target until setOrtho is called.
---@type fun(self: lupa.Draw, t: lupa.draw.Camera)
function methods.setCamera(self, t)
	assert(type(t) == "table" and t.position ~= nil, "setCamera expects { position = { x, y, z } }")
	self.camera = t

	setVec3(eye, t.position, 0, 0, 0)
	setVec3(target, t.target, 0, 0, 0)
	setVec3(up, t.up, 0, 1, 0)

	local width, height = self:targetSize()
	lpmath.mat4.lookAtInto(viewMatrix, eye, target, up)
	lpmath.mat4.perspectiveInto(projMatrix, t.fov or math.pi / 3, width / height, t.near or 0.1, t.far or 1000)
	lpmath.mat4.mulInto(self.transforms.viewProj, projMatrix, viewMatrix)

	self.customView = true
	self.projWidth, self.projHeight = nil, nil

	-- safety: the specular term needs the eye position
	local light = self.lighting
	light.cameraPos[0], light.cameraPos[1], light.cameraPos[2] = eye.x, eye.y, eye.z
end

--- Supply the view-projection matrix directly.
---@type fun(self: lupa.Draw, m: lupa.math.Mat4)
function methods.setViewProjection(self, m)
	self.transforms.viewProj = m
	self.customView = true
	self.camera = nil
	self.projWidth, self.projHeight = nil, nil
end

--- Return to the default 2D orthographic view.
---@type fun(self: lupa.Draw)
function methods.setOrtho(self)
	self.customView = false
	self.camera = nil
	self.projWidth, self.projHeight = nil, nil
end

--- Enable Blinn-Phong shading for everything drawn afterwards. Off by default.
---@type fun(self: lupa.Draw, t: lupa.draw.Light)
function methods.setLight(self, t)
	local light = self.lighting

	local dx, dy, dz = xyz(t.direction, -0.5, -1, -0.3)
	light.lightDir[0], light.lightDir[1], light.lightDir[2] = dx, dy, dz

	local cr, cg, cb = xyz(t.color, 1, 1, 1)
	light.lightColor[0], light.lightColor[1], light.lightColor[2] = cr, cg, cb

	local ar, ag, ab = xyz(t.ambient, 0.2, 0.2, 0.2)
	light.ambientColor[0], light.ambientColor[1], light.ambientColor[2] = ar, ag, ab

	light.lightEnabled = 1.0
end

--- Back to unlit: vertex colors are used directly.
---@type fun(self: lupa.Draw)
function methods.clearLight(self)
	self.lighting.lightEnabled = 0.0
end

view.methods = methods

return view
