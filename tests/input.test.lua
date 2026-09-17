local test = require("lde-test")
local Input = require("lupa.input")

---@return lupa.Input
local function newInput()
	return Input.new(nil)
end

test.it("input: a press lasts for the frame it happened in", function()
	local input = newInput()
	input:registerPressed("escape")

	test.truthy(input:wasPressed("escape"))
	test.truthy(input:isHeld("escape"))

	input:clearFrame()

	test.falsy(input:wasPressed("escape"))
	test.truthy(input:isHeld("escape"))
end)

test.it("input: a release is reported once and clears the held key", function()
	local input = newInput()
	input:registerPressed("space")
	input:clearFrame()
	input:registerReleased("space")

	test.truthy(input:wasReleased("space"))
	test.falsy(input:isHeld("space"))

	input:clearFrame()

	test.falsy(input:wasReleased("space"))
end)

test.it("input: mouse buttons can be named or numbered", function()
	local input = newInput()
	input:registerMousePressed("left")

	test.truthy(input:isMouseHeld("left"))
	test.truthy(input:isMouseHeld(1))

	input:registerMouseReleased("left")
	input:registerMousePressed(3)

	test.falsy(input:isMouseHeld("left"))
	test.truthy(input:isMouseHeld("right"))
end)

test.it("input: mouse motion accumulates within a frame and resets with it", function()
	local input = newInput()
	input:registerMouseMotion(3, -4)
	input:registerMouseMotion(2, 4)
	input:registerMouseScroll(0, 1)

	local dx, dy = input:mouseMotion()
	test.equal(dx, 5)
	test.equal(dy, 0)

	local _, scrollY = input:mouseScroll()
	test.equal(scrollY, 1)

	input:clearFrame()

	local resetX, resetY = input:mouseMotion()
	test.equal(resetX, 0)
	test.equal(resetY, 0)
end)

test.it("input: the cursor position is read back as reported", function()
	local input = newInput()
	input:registerMouseMove(12, 34)

	local x, y = input:mousePosition()
	test.equal(x, 12)
	test.equal(y, 34)
end)

test.it("input: a modifier name covers either of the keys that carry it", function()
	local input = newInput()
	input:registerPressed("left-ctrl")

	test.truthy(input:isHeld("ctrl"))
	test.truthy(input:isHeld("left-ctrl"))
	test.falsy(input:isHeld("right-ctrl"))
	test.falsy(input:isHeld("shift"))

	input:registerPressed("right-shift")
	test.truthy(input:isHeld("shift"))

	input:registerReleased("left-ctrl")
	test.falsy(input:isHeld("ctrl"))
	test.truthy(input:wasReleased("ctrl"))
end)

test.it("input: a key event carries the modifiers that were down for it", function()
	local input = newInput()
	test.falsy(input:modifiers().ctrl)

	input:registerPressed("w", { shift = false, ctrl = true, alt = false })
	test.truthy(input:modifiers().ctrl)
	test.falsy(input:modifiers().shift)

	input:registerReleased("w", { shift = true, ctrl = false, alt = false })
	test.truthy(input:modifiers().shift)
	test.falsy(input:modifiers().ctrl)
end)

test.it("input: letting go of a modifier is not a key event that still carries it", function()
	local input = newInput()

	-- safety: a backend reports the modifiers a key event found rather than the ones it
	-- leaves behind, so letting go of shift arrives with shift still set. Taking that as
	-- the state is what leaves shift stuck down until another key is pressed
	input:registerPressed("left-shift", { shift = false, ctrl = false, alt = false })
	input:registerReleased("left-shift", { shift = true, ctrl = false, alt = false })

	test.falsy(input:isHeld("shift"))
	test.falsy(input:modifiers().shift)

	input:registerPressed("left-ctrl", { shift = false, ctrl = false, alt = false })
	test.truthy(input:isHeld("ctrl"))

	input:registerReleased("left-ctrl", { shift = false, ctrl = true, alt = false })
	test.falsy(input:isHeld("ctrl"))
	test.falsy(input:modifiers().ctrl)

	-- and a modifier that is still down is still reported as down
	input:registerPressed("left-shift", { shift = false, ctrl = false, alt = false })
	input:registerPressed("w", { shift = false, ctrl = false, alt = false })
	input:registerReleased("w", { shift = true, ctrl = false, alt = false })
	test.truthy(input:isHeld("shift"))
	test.truthy(input:modifiers().shift)
end)

test.it("input: the wall clock goes forward and os.clock is not it", function()
	local lupa = require("lupa")
	local first = lupa.now()
	local sum = 0
	for index = 1, 200000 do
		sum = sum + index
	end
	local second = lupa.now()

	test.greater(second, first)
	test.less(second - first, 1)
	test.equal(sum, 20000100000)
end)

test.it("input: what a key typed is handed over apart from which key it was", function()
	local input = newInput()

	input:registerPressed("w", nil, "w")
	input:registerPressed("left-shift", nil, nil)
	input:registerPressed("w", { shift = true }, "W")
	test.equal(input:text(), "wW")

	input:clearFrame()
	test.equal(input:text(), "")

	-- and a key that types nothing adds nothing, whatever it reports as its text
	input:registerPressed("left-shift", nil, nil)
	input:registerPressed("f1", nil, nil)
	input:registerPressed("backspace", nil, "\8")
	input:registerPressed("tab", nil, "\9")
	test.equal(input:text(), "")
	test.truthy(input:isHeld("shift"))
end)
