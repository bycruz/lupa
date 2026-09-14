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

--- dst = a * b. `dst` may alias `a` or `b`: every element is read into a local
--- before anything is written. Unrolled because this is what a 3D transform
--- stack ends up calling, once per object.
---@param dst lupa.math.Mat4
---@param a lupa.math.Mat4
---@param b lupa.math.Mat4
function mat4.mulInto(dst, a, b)
	local A, B, D = a.m, b.m, dst.m

	local a00, a01, a02, a03 = A[0], A[4], A[8], A[12]
	local a10, a11, a12, a13 = A[1], A[5], A[9], A[13]
	local a20, a21, a22, a23 = A[2], A[6], A[10], A[14]
	local a30, a31, a32, a33 = A[3], A[7], A[11], A[15]

	local b00, b01, b02, b03 = B[0], B[4], B[8], B[12]
	local b10, b11, b12, b13 = B[1], B[5], B[9], B[13]
	local b20, b21, b22, b23 = B[2], B[6], B[10], B[14]
	local b30, b31, b32, b33 = B[3], B[7], B[11], B[15]

	D[0]  = a00 * b00 + a01 * b10 + a02 * b20 + a03 * b30
	D[1]  = a10 * b00 + a11 * b10 + a12 * b20 + a13 * b30
	D[2]  = a20 * b00 + a21 * b10 + a22 * b20 + a23 * b30
	D[3]  = a30 * b00 + a31 * b10 + a32 * b20 + a33 * b30

	D[4]  = a00 * b01 + a01 * b11 + a02 * b21 + a03 * b31
	D[5]  = a10 * b01 + a11 * b11 + a12 * b21 + a13 * b31
	D[6]  = a20 * b01 + a21 * b11 + a22 * b21 + a23 * b31
	D[7]  = a30 * b01 + a31 * b11 + a32 * b21 + a33 * b31

	D[8]  = a00 * b02 + a01 * b12 + a02 * b22 + a03 * b32
	D[9]  = a10 * b02 + a11 * b12 + a12 * b22 + a13 * b32
	D[10] = a20 * b02 + a21 * b12 + a22 * b22 + a23 * b32
	D[11] = a30 * b02 + a31 * b12 + a32 * b22 + a33 * b32

	D[12] = a00 * b03 + a01 * b13 + a02 * b23 + a03 * b33
	D[13] = a10 * b03 + a11 * b13 + a12 * b23 + a13 * b33
	D[14] = a20 * b03 + a21 * b13 + a22 * b23 + a23 * b33
	D[15] = a30 * b03 + a31 * b13 + a32 * b23 + a33 * b33
end

---@param a lupa.math.Mat4
---@param b lupa.math.Mat4
---@return lupa.math.Mat4
function mat4.mul(a, b)
	local m = mat4Type()
	mat4.mulInto(m, a, b)
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

--- Write a rotation about `axis` into `m` without allocating.
---@param m lupa.math.Mat4
---@param angle number radians
---@param x number
---@param y number
---@param z number
function mat4.rotateInto(m, angle, x, y, z)
	local len = math.sqrt(x * x + y * y + z * z)
	x, y, z = x / len, y / len, z / len
	local c = math.cos(angle)
	local s = math.sin(angle)
	local t = 1 - c
	local e = m.m
	e[idx(0, 0)] = t * x * x + c
	e[idx(0, 1)] = t * x * y - s * z
	e[idx(0, 2)] = t * x * z + s * y
	e[idx(0, 3)] = 0
	e[idx(1, 0)] = t * x * y + s * z
	e[idx(1, 1)] = t * y * y + c
	e[idx(1, 2)] = t * y * z - s * x
	e[idx(1, 3)] = 0
	e[idx(2, 0)] = t * x * z - s * y
	e[idx(2, 1)] = t * y * z + s * x
	e[idx(2, 2)] = t * z * z + c
	e[idx(2, 3)] = 0
	e[idx(3, 0)] = 0
	e[idx(3, 1)] = 0
	e[idx(3, 2)] = 0
	e[idx(3, 3)] = 1
	return m
end

---@param angle number radians
---@param x number
---@param y number
---@param z number
---@return lupa.math.Mat4
function mat4.rotate(angle, x, y, z)
	return mat4.rotateInto(mat4Type(), angle, x, y, z)
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
