local test = require("lde-test")
local lpmath = require("lupa.math")

---@type fun(m: lupa.math.Mat4, x: number, y: number, z: number): number, number, number, number
local function apply(m, x, y, z)
	local e = m.m
	return e[0] * x + e[4] * y + e[8] * z + e[12],
		e[1] * x + e[5] * y + e[9] * z + e[13],
		e[2] * x + e[6] * y + e[10] * z + e[14],
		e[3] * x + e[7] * y + e[11] * z + e[15]
end

--- The matrices are stored as f32, so comparisons need a tolerance.
---@type fun(a: number, b: number)
local function almostEqual(a, b)
	if math.abs(a - b) > 1e-5 then
		error(string.format("expected %g to be %g", a, b))
	end
end

test.it("math: identity leaves a point alone", function()
	local x, y, z, w = apply(lpmath.mat4.identity(), 3, -4, 5)
	test.equal(x, 3) test.equal(y, -4) test.equal(z, 5) test.equal(w, 1)
end)

test.it("math: ortho maps the window corners to the clip cube", function()
	local m = lpmath.mat4.ortho(0, 800, 0, 600, -1, 1)

	local x0, y0 = apply(m, 0, 0, 0)
	almostEqual(x0, -1) almostEqual(y0, -1)

	local x1, y1 = apply(m, 800, 600, 0)
	almostEqual(x1, 1) almostEqual(y1, 1)
end)

test.it("math: ortho puts y = 0 at the bottom", function()
	local m = lpmath.mat4.ortho(0, 800, 0, 600, -1, 1)

	local _, low = apply(m, 0, 100, 0)
	local _, high = apply(m, 0, 500, 0)
	test.less(low, high)
end)

test.it("math: perspective keeps a point on the view axis centred", function()
	local m = lpmath.mat4.perspective(math.pi / 3, 16 / 9, 0.1, 100)
	local x, y = apply(m, 0, 0, -10)
	test.equal(x, 0)
	test.equal(y, 0)
end)

test.it("math: lookAt places the eye at the origin looking down -Z", function()
	local eye = lpmath.vec3.new(0, 0, 10)
	local target = lpmath.vec3.new(0, 0, 0)
	local up = lpmath.vec3.new(0, 1, 0)

	local view = lpmath.mat4.lookAt(eye, target, up)
	local x, y, z = apply(view, 0, 0, 0)

	-- The target, ten units in front of the eye, lands ten units along -Z.
	test.equal(x, 0)
	test.equal(y, 0)
	test.equal(z, -10)
end)

test.it("math: multiplying by identity changes nothing", function()
	local m = lpmath.mat4.ortho(0, 800, 0, 600, -1, 1)
	local product = lpmath.mat4.mul(m, lpmath.mat4.identity())

	local ax, ay = apply(m, 123, 456, 0)
	local bx, by = apply(product, 123, 456, 0)
	test.equal(ax, bx)
	test.equal(ay, by)
end)

test.it("math: ortho maps the near plane to 0 and the far plane to 1", function()
	-- safety: a shadow pass renders through an orthographic projection, so a depth
	-- range outside [0, 1] would clip it away entirely
	local m = lpmath.mat4.ortho(-10, 10, -10, 10, 0.5, 20.5)

	local _, _, near = apply(m, 0, 0, -0.5)
	local _, _, far = apply(m, 0, 0, -20.5)
	almostEqual(near, 0)
	almostEqual(far, 1)
end)

test.it("math: ortho written over a perspective leaves none of it behind", function()
	-- safety: the frame's viewProj is written in place, so an ortho drawn after a
	-- camera would keep the camera's terms if the write missed any of them
	local m = lpmath.mat4.perspective(math.pi / 3, 16 / 9, 0.1, 100)
	lpmath.mat4.orthoInto(m, 0, 800, 0, 600, -1, 1)

	local x, y, z, w = apply(m, 800, 600, 0)
	almostEqual(x, 1)
	almostEqual(y, 1)
	almostEqual(z, 0.5)
	almostEqual(w, 1)
end)
