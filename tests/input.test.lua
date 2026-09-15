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
