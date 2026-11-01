local gpu = require("lupa.draw.gpu")
local lpmath = require("lupa.math")
local limits = require("lupa.draw.limits")
---@type lupa.draw.Records
local records = require("lupa.draw.records")

local eye = lpmath.vec3.new(0, 0, 0)
local target = lpmath.vec3.new(0, 0, 0)
local up = lpmath.vec3.new(0, 1, 0)
local viewMatrix = lpmath.mat4.identity()
local projMatrix = lpmath.mat4.identity()
local lightView = lpmath.mat4.identity()
local lightProj = lpmath.mat4.identity()
local lightDir = lpmath.vec3.new(0, -1, 0)
local lightEye = lpmath.vec3.new(0, 0, 0)
local lightCenter = lpmath.vec3.new(0, 0, 0)

local casterX, casterY, casterZ = 0, -1, 0

---@alias lupa.draw.XYZ { x: number, y: number, z: number } | number[]

---@class lupa.draw.Camera
---@field position lupa.draw.XYZ
---@field target lupa.draw.XYZ? defaults to the origin
---@field up lupa.draw.XYZ? defaults to +Y
---@field fov number? radians, defaults to pi/3
---@field near number? defaults to 0.1
---@field far number? defaults to 1000

---@class lupa.draw.ShadowOptions
---@field distance number? how far shadows reach in world units, defaults to 128
---@field cascades number? how many maps to split that into, defaults to 4
---@field split number? 0 to 1, how much the splits favour the near view, defaults to 0.6
---@field blend number? share of a cascade's range blended into the next, defaults to 0.1
---@field filter number? width of the filter in shadow texels, defaults to 2
---@field bias number? depth offset that keeps a surface from shadowing itself
---@field normalBias number? shadow texels a sample is pushed along its normal

---@class lupa.draw.DirectionalLight
---@field dir lupa.draw.XYZ the direction the light travels in
---@field color lupa.draw.XYZ? defaults to white
---@field shadows boolean|lupa.draw.ShadowOptions? whether this light casts, and how

---@class lupa.draw.PointLight
---@field pos lupa.draw.XYZ where the light sits
---@field radius number? how far it reaches, defaults to 16
---@field color lupa.draw.XYZ? defaults to white

---@alias lupa.draw.Light lupa.draw.DirectionalLight|lupa.draw.PointLight

--- What the far end of the view fades into, so the world does not end in a line.
---@class lupa.draw.Fog
---@field color lupa.draw.XYZ? what it fades to, defaults to a mid grey
---@field near number? how far away the fade begins, defaults to a third of `far`
---@field far number how far away the fade is complete, in world units, 0 to turn it off

---@class lupa.draw.Lighting
---@field ambient lupa.draw.XYZ? defaults to 0.2 grey
---@field lights lupa.draw.Light[]? up to lupa.draw.limits.lights of them
---@field fog lupa.draw.Fog? defaults to no fade

---@class lupa.draw.View
---@field setCamera fun(self: lupa.Draw, t: lupa.draw.Camera)
---@field setViewProjection fun(self: lupa.Draw, m: lupa.math.Mat4)
---@field setOrtho fun(self: lupa.Draw)
---@field setLighting fun(self: lupa.Draw, t: lupa.draw.Lighting)
---@field refreshShadow fun(draw: lupa.Draw, width: number, height: number)
---@field refreshOverlay fun(draw: lupa.Draw, width: number, height: number)
---@field clearLighting fun(self: lupa.Draw)
local view = {}

function view.newState()
	local transforms, lighting = records.newTransforms(), records.newLighting()
	---@cast lighting lupa.draw.LightingUniform

	-- safety: the half texel a wrapped sample stays inside its tile is fixed by the
	-- texture array's size, so it is set once rather than every frame
	lighting.texelInsetU = gpu.TEXEL_INSET_U
	lighting.texelInsetV = gpu.TEXEL_INSET_V

	return transforms, lighting
end

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

---@type fun(draw: lupa.Draw, width: number, height: number)
function view.refreshOverlay(draw, width, height)
	lpmath.mat4.orthoInto(draw.overlayTransforms.viewProj, 0, width, 0, height, -1, 1)

	local lighting = draw.overlayLighting
	lighting.lightCount = 0.0
	lighting.ambientColor[0], lighting.ambientColor[1], lighting.ambientColor[2] = 1, 1, 1
	lighting.shadowEnabled = 0.0
	lighting.shadowCascades = 0.0
	lighting.fogFar, lighting.fogNear = 0, 0
end

---@type fun(draw: lupa.Draw, width: number, height: number)
function view.refreshProjection(draw, width, height)
	if draw.customView or (draw.projWidth == width and draw.projHeight == height) then
		return
	end

	draw.projWidth, draw.projHeight = width, height
	lpmath.mat4.orthoInto(draw.transforms.viewProj, 0, width, 0, height, -1, 1)
end

local methods = {}

---@type fun(self: lupa.Draw, t: lupa.draw.Camera)
function methods.setCamera(self, t)
	assert(type(t) == "table" and t.position ~= nil, "setCamera expects { position = { x, y, z } }")
	self.camera = t

	setVec3(eye, t.position, 0, 0, 0)
	setVec3(target, t.target, 0, 0, 0)
	setVec3(up, t.up, 0, 1, 0)

	local width, height = self:targetSize()
	---@cast width number
	---@cast height number
	lpmath.mat4.lookAtInto(viewMatrix, eye, target, up)
	lpmath.mat4.perspectiveInto(projMatrix, t.fov or math.pi / 3, width / height, t.near or 0.1, t.far or 1000)
	lpmath.mat4.mulInto(self.transforms.viewProj, projMatrix, viewMatrix)

	self.customView = true
	self.projWidth, self.projHeight = nil, nil

	-- safety: the specular term needs the eye position
	local light = self.lighting
	light.cameraPos[0], light.cameraPos[1], light.cameraPos[2] = eye.x, eye.y, eye.z
end

---@type fun(self: lupa.Draw, m: lupa.math.Mat4)
function methods.setViewProjection(self, m)
	self.transforms.viewProj = m
	self.customView = true
	self.camera = nil
	self.projWidth, self.projHeight = nil, nil
end

---@type fun(self: lupa.Draw)
function methods.setOrtho(self)
	self.customView = false
	self.camera = nil
	self.projWidth, self.projHeight = nil, nil
end

---@type fun(index: number, cascades: number, near: number, far: number, lambda: number): number
local function splitDistance(index, cascades, near, far, lambda)
	local even = near + (far - near) * (index / cascades)
	local log = near * (far / near) ^ (index / cascades)
	return lambda * log + (1 - lambda) * even
end

-- safety: the splits are known as soon as the lighting is set, because a game trims what
-- each cascade draws as it draws it; the fit waits for the frame's target size
---@type fun(draw: lupa.Draw)
local function publishSplits(draw)
	local lighting = draw.lighting
	local cascades = draw.shadowCascades
	local near = math.max(draw.camera and draw.camera.near or 0.1, 0.01)

	for index = 1, cascades do
		local to = splitDistance(index, cascades, near, draw.shadowDistance, draw.shadowSplit)
		lighting.shadowSplits[index - 1] = to
		draw.shadowSplits[index] = to
	end
end

---@type fun(self: lupa.Draw, t: lupa.draw.Lighting)
function methods.setLighting(self, t)
	local lighting = self.lighting
	local ar, ag, ab = xyz(t.ambient, 0.2, 0.2, 0.2)
	lighting.ambientColor[0], lighting.ambientColor[1], lighting.ambientColor[2] = ar, ag, ab

	local fog = t.fog
	local fr, fg, fb = xyz(fog and fog.color, 0.5, 0.5, 0.5)
	lighting.fogColor[0], lighting.fogColor[1], lighting.fogColor[2] = fr, fg, fb
	lighting.fogFar = fog and fog.far or 0
	lighting.fogNear = fog and (fog.near or lighting.fogFar * 0.3) or 0

	local lights = t.lights or {}
	assert(#lights <= limits.lights,
		string.format("lupa: at most %d lights in a frame, got %d", limits.lights, #lights))

	local caster = -1
	local shadows

	for index = 1, #lights do
		local source = lights[index]
		local light = lighting.lights[index - 1]
		local cr, cg, cb = xyz(source.color, 1, 1, 1)
		light.color[0], light.color[1], light.color[2] = cr, cg, cb

		if source.dir ~= nil then
			local dx, dy, dz = xyz(source.dir, -0.5, -1, -0.3)
			light.kind = 0.0
			light.at[0], light.at[1], light.at[2] = dx, dy, dz
			light.radius = 0.0

			if shadows == nil and source.shadows and source.shadows ~= false then
				caster, shadows = index - 1, source.shadows
				casterX, casterY, casterZ = dx, dy, dz
			end
		else
			assert(source.pos ~= nil, "lupa: a light needs a dir, or a pos and a radius")
			local px, py, pz = xyz(source.pos, 0, 0, 0)
			light.kind = 1.0
			light.at[0], light.at[1], light.at[2] = px, py, pz
			light.radius = source.radius or 16
		end
	end

	lighting.lightCount = #lights
	lighting.shadowLight = caster

	self.shadowEnabled = caster >= 0
	if self.shadowEnabled then
		---@type lupa.draw.ShadowOptions
		local options = type(shadows) == "table" and shadows or {}
		local cascades = options.cascades or limits.shadowCascades

		assert(cascades >= 1 and cascades <= limits.shadowCascades,
			string.format("lupa: shadows take 1 to %d cascades, got %s",
				limits.shadowCascades, tostring(options.cascades)))

		self.shadowCascades = math.floor(cascades)
		self.shadowDistance = options.distance or limits.shadowDistance
		self.shadowSplit = options.split or limits.shadowSplit
		self.shadowBlend = options.blend or limits.shadowBlend
		self.shadowFilter = options.filter or limits.shadowFilter
		self.shadowBias = options.bias or limits.shadowBias
		self.shadowNormalBias = options.normalBias or limits.shadowNormalBias
		self.shadowCasterDepth = limits.shadowCasterDepth
		lighting.shadowEnabled = 1.0
		publishSplits(self)
	else
		lighting.shadowEnabled = 0.0
	end
end

---@type fun(self: lupa.Draw)
function methods.clearLighting(self)
	local lighting = self.lighting
	lighting.lightCount = 0.0
	lighting.ambientColor[0], lighting.ambientColor[1], lighting.ambientColor[2] = 1, 1, 1
	lighting.shadowEnabled = 0.0
	lighting.shadowCascades = 0.0
	lighting.shadowLight = -1.0
	lighting.fogFar, lighting.fogNear = 0, 0
	self.shadowEnabled = false
end

-- safety: the box is fitted to the slice's bounding sphere rather than the slice, and its
-- centre snapped to a whole texel, so the map's texels stay put as the camera moves
---@param draw lupa.Draw
---@param index number
---@param near number
---@param far number
---@param aspect number
---@param tangent number
---@param size number
---@param casterDepth number
local function fitCascade(draw, index, near, far, aspect, tangent, size, casterDepth)
	local middle = (near + far) * 0.5
	local lateral = far * tangent * math.sqrt(1 + aspect * aspect)
	local radius = math.sqrt((middle - near) ^ 2 + lateral ^ 2)
	local texel = 2 * radius / size

	local camera = draw.camera
	local ex, ey, ez = xyz(camera and camera.position, 0, 0, 0)
	local tx, ty, tz = xyz(camera and camera.target, ex, ey, ez - 1)
	local dx, dy, dz = tx - ex, ty - ey, tz - ez
	local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
	dx, dy, dz = dx / distance, dy / distance, dz / distance

	local cx = ex + dx * middle
	local cy = ey + dy * middle
	local cz = ez + dz * middle

	local rx = lightDir.y * up.z - lightDir.z * up.y
	local ry = lightDir.z * up.x - lightDir.x * up.z
	local rz = lightDir.x * up.y - lightDir.y * up.x
	local rlen = math.sqrt(rx * rx + ry * ry + rz * rz)
	rx, ry, rz = rx / rlen, ry / rlen, rz / rlen

	local ux = ry * lightDir.z - rz * lightDir.y
	local uy = rz * lightDir.x - rx * lightDir.z
	local uz = rx * lightDir.y - ry * lightDir.x

	local alongRight = cx * rx + cy * ry + cz * rz
	local alongUp = cx * ux + cy * uy + cz * uz
	local snapRight = math.floor(alongRight / texel + 0.5) * texel - alongRight
	local snapUp = math.floor(alongUp / texel + 0.5) * texel - alongUp

	lightCenter.x = cx + rx * snapRight + ux * snapUp
	lightCenter.y = cy + ry * snapRight + uy * snapUp
	lightCenter.z = cz + rz * snapRight + uz * snapUp

	-- safety: the light sits a sphere and the shadow caster depth back, so what
	-- stands between the light and the slice, a hill above a valley, is in the map
	local back = radius + casterDepth
	lightEye.x = lightCenter.x - lightDir.x * back
	lightEye.y = lightCenter.y - lightDir.y * back
	lightEye.z = lightCenter.z - lightDir.z * back

	lpmath.mat4.lookAtInto(lightView, lightEye, lightCenter, up)
	lpmath.mat4.orthoInto(lightProj, -radius, radius, -radius, radius, 0.1, back * 2)
	lpmath.mat4.mulInto(draw.transforms.lightViewProj[index], lightProj, lightView)

	return texel
end

---@type fun(draw: lupa.Draw, width: number, height: number)
function view.refreshShadow(draw, width, height)
	lightDir.x, lightDir.y, lightDir.z = casterX, casterY, casterZ
	local length = math.sqrt(lightDir.x * lightDir.x + lightDir.y * lightDir.y + lightDir.z * lightDir.z)
	lightDir.x, lightDir.y, lightDir.z = lightDir.x / length, lightDir.y / length, lightDir.z / length

	-- safety: a light pointing straight down would collapse lookAt if it kept +Y
	-- as its up vector
	if math.abs(lightDir.y) > 0.99 then
		up.x, up.y, up.z = 0, 0, 1
	else
		up.x, up.y, up.z = 0, 1, 0
	end

	local lighting = draw.lighting
	local cascades = draw.shadowCascades
	local camera = draw.camera
	local fov = camera and camera.fov or math.pi / 3
	local near = math.max(camera and camera.near or 0.1, 0.01)
	local aspect = width / height
	local size = draw.shadow.size
	local tangent = math.tan(fov * 0.5)

	-- safety: a frame that set a projection of its own has no camera and is fitted as one
	-- at the origin looking down -Z, and its splits may predate the camera
	publishSplits(draw)

	local from = near
	for index = 1, cascades do
		local to = lighting.shadowSplits[index - 1]
		local texel = fitCascade(draw, index - 1, from, to, aspect, tangent, size, draw.shadowCasterDepth)

		lighting.shadowTexels[index - 1] = texel
		from = to
	end

	lighting.shadowEnabled = 1.0
	lighting.shadowCascades = cascades
	lighting.shadowBlend = draw.shadowBlend
	lighting.shadowFilter = draw.shadowFilter
	lighting.shadowBias = draw.shadowBias
	lighting.shadowNormalBias = draw.shadowNormalBias
	lighting.shadowTexel = 1.0 / size

	local ex, ey, ez = xyz(camera and camera.position, 0, 0, 0)
	local tx, ty, tz = xyz(camera and camera.target, ex, ey, ez - 1)
	local dx, dy, dz = tx - ex, ty - ey, tz - ez
	local viewLength = math.sqrt(dx * dx + dy * dy + dz * dz)
	lighting.cameraForward[0] = dx / viewLength
	lighting.cameraForward[1] = dy / viewLength
	lighting.cameraForward[2] = dz / viewLength
end

view.methods = methods

return view
