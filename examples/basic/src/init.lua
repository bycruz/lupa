local lupa = require("lupa")

---@type lupa.App<{ mesh: number }>
local App = {}

function App:start(assets)
	-- self.mesh = assets:loadMesh("assets/monkey.obj")
end

function App:update(dt, input)
	if input:wasPressed("escape") then
		-- Provided by lupa
		self:quit()
	end
end

function App:draw(draw)
	draw:rect(10, 10, 500, 100)
end

lupa.run(App)
