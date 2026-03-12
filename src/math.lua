local ffi = require("ffi")

ffi.cdef [[
    typedef struct { float m[16]; } LupaMat4;
    typedef struct { float x, y, z; } LupaVec3;
    typedef struct { float x, y, z, w; } LupaVec4;
    typedef struct { float x, y; } LupaVec2;
]]

local mat4 = {}

---@class lupa.math.Mat4: ffi.cdata*
---@field m number[16]

---@class lupa.math.Vec3: ffi.cdata*
---@field x number
---@field y number
---@field z number

---@class lupa.math.Vec4: ffi.cdata*
---@field x number
---@field y number
---@field z number
---@field w number

---@class lupa.math.Vec2: ffi.cdata*
---@field x number
---@field y number

---@type fun(): lupa.math.Mat4
local mat4Type = ffi.typeof("LupaMat4")

---@type fun(x: number, y: number, z: number): lupa.math.Vec3
local vec3Type = ffi.typeof("LupaVec3")

---@type fun(x: number, y: number, z: number, w: number): lupa.math.Vec4
local vec4Type = ffi.typeof("LupaVec4")

---@type fun(x: number, y: number): lupa.math.Vec2
local vec2Type = ffi.typeof("LupaVec2")

-- Column-major indexing helper: col * 4 + row
---@param row number
---@param col number
local function idx(row, col)
	return col * 4 + row
end

function mat4.identity()
	local m = mat4Type()
	m.m[idx(0, 0)] = 1
	m.m[idx(1, 1)] = 1
	m.m[idx(2, 2)] = 1
	m.m[idx(3, 3)] = 1
	return m
end

---@param left number
---@param right number
---@param bottom number
---@param top number
---@param near number
---@param far number
function mat4.ortho(left, right, bottom, top, near, far)
	local m = mat4Type()
	m.m[idx(0, 0)] = 2 / (right - left)
	m.m[idx(1, 1)] = 2 / (top - bottom)
	m.m[idx(2, 2)] = 1 / (far - near)
	m.m[idx(0, 3)] = -(right + left) / (right - left)
	m.m[idx(1, 3)] = -(top + bottom) / (top - bottom)
	m.m[idx(2, 3)] = -near / (far - near)
	m.m[idx(3, 3)] = 1
	return m
end

---@param fovy number radians
---@param aspect number
---@param near number
---@param far number
function mat4.perspective(fovy, aspect, near, far)
	local m = mat4Type()
	local tanHalf = math.tan(fovy / 2)
	m.m[idx(0, 0)] = 1 / (aspect * tanHalf)
	m.m[idx(1, 1)] = 1 / tanHalf
	m.m[idx(2, 2)] = far / (near - far)
	m.m[idx(2, 3)] = -(far * near) / (far - near)
	m.m[idx(3, 2)] = -1
	return m
end

---@param eye lupa.math.Vec3
---@param center lupa.math.Vec3
---@param up lupa.math.Vec3
function mat4.lookAt(eye, center, up)
	local fx = center.x - eye.x
	local fy = center.y - eye.y
	local fz = center.z - eye.z
	local flen = math.sqrt(fx * fx + fy * fy + fz * fz)
	fx, fy, fz = fx / flen, fy / flen, fz / flen

	local rx = fy * up.z - fz * up.y
	local ry = fz * up.x - fx * up.z
	local rz = fx * up.y - fy * up.x
	local rlen = math.sqrt(rx * rx + ry * ry + rz * rz)
	rx, ry, rz = rx / rlen, ry / rlen, rz / rlen

	local ux = ry * fz - rz * fy
	local uy = rz * fx - rx * fz
	local uz = rx * fy - ry * fx

	local m = mat4Type()
	m.m[idx(0, 0)] = rx
	m.m[idx(0, 1)] = ry
	m.m[idx(0, 2)] = rz
	m.m[idx(1, 0)] = ux
	m.m[idx(1, 1)] = uy
	m.m[idx(1, 2)] = uz
	m.m[idx(2, 0)] = -fx
	m.m[idx(2, 1)] = -fy
	m.m[idx(2, 2)] = -fz
	m.m[idx(0, 3)] = -(rx * eye.x + ry * eye.y + rz * eye.z)
	m.m[idx(1, 3)] = -(ux * eye.x + uy * eye.y + uz * eye.z)
	m.m[idx(2, 3)] = (fx * eye.x + fy * eye.y + fz * eye.z)
	m.m[idx(3, 3)] = 1
	return m
end

---@param a lupa.math.Mat4
---@param b lupa.math.Mat4
function mat4.mul(a, b)
	local m = mat4Type()
	for col = 0, 3 do
		for row = 0, 3 do
			local sum = 0
			for k = 0, 3 do
				sum = sum + a.m[idx(row, k)] * b.m[idx(k, col)]
			end
			m.m[idx(row, col)] = sum
		end
	end
	return m
end

---@param tx number
---@param ty number
---@param tz number
function mat4.translate(tx, ty, tz)
	local m = mat4.identity()
	m.m[idx(0, 3)] = tx
	m.m[idx(1, 3)] = ty
	m.m[idx(2, 3)] = tz
	return m
end

---@param sx number
---@param sy number
---@param sz number
function mat4.scale(sx, sy, sz)
	local m = mat4Type()
	m.m[idx(0, 0)] = sx
	m.m[idx(1, 1)] = sy
	m.m[idx(2, 2)] = sz
	m.m[idx(3, 3)] = 1
	return m
end

---@param angle number radians
---@param x number
---@param y number
---@param z number
function mat4.rotate(angle, x, y, z)
	local len = math.sqrt(x * x + y * y + z * z)
	x, y, z = x / len, y / len, z / len
	local c = math.cos(angle)
	local s = math.sin(angle)
	local t = 1 - c
	local m = mat4Type()
	m.m[idx(0, 0)] = t * x * x + c
	m.m[idx(0, 1)] = t * x * y - s * z
	m.m[idx(0, 2)] = t * x * z + s * y
	m.m[idx(1, 0)] = t * x * y + s * z
	m.m[idx(1, 1)] = t * y * y + c
	m.m[idx(1, 2)] = t * y * z - s * x
	m.m[idx(2, 0)] = t * x * z - s * y
	m.m[idx(2, 1)] = t * y * z + s * x
	m.m[idx(2, 2)] = t * z * z + c
	m.m[idx(3, 3)] = 1
	return m
end

local vec3 = {}
vec3.new = vec3Type

---@param a lupa.math.Vec3
---@param b lupa.math.Vec3
function vec3.cross(a, b)
	return vec3Type(
		a.y * b.z - a.z * b.y,
		a.z * b.x - a.x * b.z,
		a.x * b.y - a.y * b.x
	)
end

---@param a lupa.math.Vec3
---@param b lupa.math.Vec3
function vec3.dot(a, b)
	return a.x * b.x + a.y * b.y + a.z * b.z
end

---@param a lupa.math.Vec3
function vec3.normalize(a)
	local len = math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
	return vec3Type(a.x / len, a.y / len, a.z / len)
end

return { vec3 = vec3, mat4 = mat4 }
