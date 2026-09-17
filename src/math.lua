local ffi = require("ffi")

ffi.cdef [[
    typedef struct { float m[16]; } LupaMat4;
    typedef struct { float x, y, z; } LupaVec3;
]]

--- safety: column-major, indexed column * 4 + row, as std140 lays a mat4 out
---@class lupa.math.Mat4: ffi.cdata*
---@field m number[16]

---@class lupa.math.Vec3: ffi.cdata*
---@field x number
---@field y number
---@field z number

---@class lupa.math.Mat4Kit
local mat4 = {}

---@class lupa.math.Vec3Kit
---@field new fun(x: number, y: number, z: number): lupa.math.Vec3

---@type fun(): lupa.math.Mat4
---@diagnostic disable-next-line: assign-type-mismatch
local mat4Type = ffi.typeof("LupaMat4")

---@type fun(x: number, y: number, z: number): lupa.math.Vec3
---@diagnostic disable-next-line: assign-type-mismatch
local vec3Type = ffi.typeof("LupaVec3")

---@type fun(row: number, col: number): number
local function idx(row, col)
	return col * 4 + row
end

---@type fun(): lupa.math.Mat4
function mat4.identity()
	local m = mat4Type()
	m.m[idx(0, 0)] = 1
	m.m[idx(1, 1)] = 1
	m.m[idx(2, 2)] = 1
	m.m[idx(3, 3)] = 1
	return m
end

--- safety: every element is written, because the matrix may hold another
--- projection and a leftover term would corrupt the result
---@param dst lupa.math.Mat4
---@param left number
---@param right number
---@param bottom number
---@param top number
---@param near number
---@param far number
---@return lupa.math.Mat4
function mat4.orthoInto(dst, left, right, bottom, top, near, far)
	local m = dst.m
	m[idx(0, 0)] = 2 / (right - left)
	m[idx(0, 1)] = 0
	m[idx(0, 2)] = 0
	m[idx(0, 3)] = -(right + left) / (right - left)
	m[idx(1, 0)] = 0
	m[idx(1, 1)] = 2 / (top - bottom)
	m[idx(1, 2)] = 0
	m[idx(1, 3)] = -(top + bottom) / (top - bottom)
	m[idx(2, 0)] = 0
	m[idx(2, 1)] = 0
	-- safety: the depth range is [0, 1], matching the perspective projection and
	-- what a depth attachment expects
	m[idx(2, 2)] = 1 / (near - far)
	m[idx(2, 3)] = near / (near - far)
	m[idx(3, 0)] = 0
	m[idx(3, 1)] = 0
	m[idx(3, 2)] = 0
	m[idx(3, 3)] = 1
	return dst
end

---@type fun(left: number, right: number, bottom: number, top: number, near: number, far: number): lupa.math.Mat4
function mat4.ortho(left, right, bottom, top, near, far)
	return mat4.orthoInto(mat4Type(), left, right, bottom, top, near, far)
end

---@type fun(dst: lupa.math.Mat4, fovy: number, aspect: number, near: number, far: number): lupa.math.Mat4
function mat4.perspectiveInto(dst, fovy, aspect, near, far)
	local tanHalf = math.tan(fovy / 2)
	local m = dst.m
	m[idx(0, 0)] = 1 / (aspect * tanHalf)
	m[idx(0, 1)] = 0
	m[idx(0, 2)] = 0
	m[idx(0, 3)] = 0
	m[idx(1, 0)] = 0
	m[idx(1, 1)] = 1 / tanHalf
	m[idx(1, 2)] = 0
	m[idx(1, 3)] = 0
	m[idx(2, 0)] = 0
	m[idx(2, 1)] = 0
	m[idx(2, 2)] = far / (near - far)
	m[idx(2, 3)] = -(far * near) / (far - near)
	m[idx(3, 0)] = 0
	m[idx(3, 1)] = 0
	m[idx(3, 2)] = -1
	m[idx(3, 3)] = 0
	return dst
end

---@type fun(fovy: number, aspect: number, near: number, far: number): lupa.math.Mat4
function mat4.perspective(fovy, aspect, near, far)
	return mat4.perspectiveInto(mat4Type(), fovy, aspect, near, far)
end

---@type fun(dst: lupa.math.Mat4, eye: lupa.math.Vec3, center: lupa.math.Vec3, up: lupa.math.Vec3): lupa.math.Mat4
function mat4.lookAtInto(dst, eye, center, up)
	local fx, fy, fz = center.x - eye.x, center.y - eye.y, center.z - eye.z
	local flen = math.sqrt(fx * fx + fy * fy + fz * fz)
	fx, fy, fz = fx / flen, fy / flen, fz / flen

	local rx, ry, rz = fy * up.z - fz * up.y, fz * up.x - fx * up.z, fx * up.y - fy * up.x
	local rlen = math.sqrt(rx * rx + ry * ry + rz * rz)
	rx, ry, rz = rx / rlen, ry / rlen, rz / rlen

	local ux, uy, uz = ry * fz - rz * fy, rz * fx - rx * fz, rx * fy - ry * fx

	local m = dst.m
	m[idx(0, 0)] = rx
	m[idx(0, 1)] = ry
	m[idx(0, 2)] = rz
	m[idx(1, 0)] = ux
	m[idx(1, 1)] = uy
	m[idx(1, 2)] = uz
	m[idx(2, 0)] = -fx
	m[idx(2, 1)] = -fy
	m[idx(2, 2)] = -fz
	m[idx(0, 3)] = -(rx * eye.x + ry * eye.y + rz * eye.z)
	m[idx(1, 3)] = -(ux * eye.x + uy * eye.y + uz * eye.z)
	m[idx(2, 3)] = fx * eye.x + fy * eye.y + fz * eye.z
	m[idx(3, 0)] = 0
	m[idx(3, 1)] = 0
	m[idx(3, 2)] = 0
	m[idx(3, 3)] = 1
	return dst
end

---@type fun(eye: lupa.math.Vec3, center: lupa.math.Vec3, up: lupa.math.Vec3): lupa.math.Mat4
function mat4.lookAt(eye, center, up)
	return mat4.lookAtInto(mat4Type(), eye, center, up)
end

--- safety: dst may alias a or b, so every element is read into a local first
---@type fun(dst: lupa.math.Mat4, a: lupa.math.Mat4, b: lupa.math.Mat4)
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

---@type fun(a: lupa.math.Mat4, b: lupa.math.Mat4): lupa.math.Mat4
function mat4.mul(a, b)
	local m = mat4Type()
	mat4.mulInto(m, a, b)
	return m
end

---@type fun(m: lupa.math.Mat4, angle: number, x: number, y: number, z: number): lupa.math.Mat4
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

---@type lupa.math.Vec3Kit
local vec3 = { new = vec3Type }

return { vec3 = vec3, mat4 = mat4 }
