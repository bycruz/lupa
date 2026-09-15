local build = require("lde-build")

local sep = string.sub(package.config, 1, 1)

--- hood's opengl backend compiles GLSL itself, so it takes the source text,
--- while vulkan takes SPIR-V.
local isOpengl = os.getenv("BACKEND") == "opengl"

local escapes = {
	[34] = '\\"',
	[92] = "\\\\",
	[9] = "\\t",
	[10] = "\\n",
	[13] = "\\r"
}

--- Escapes quotes, backslashes and control characters so that both GLSL source
--- and binary SPIR-V survive as a Lua string literal. Numeric escapes are always
--- three digits wide, otherwise "\10" followed by a literal digit byte would be
--- read back as a single character.
---@param data string
---@return string
local function toLuaLiteral(data)
	return (data:gsub("[%z\1-\31\\\"]", function(char)
		return escapes[char:byte()] or string.format("\\%03d", char:byte())
	end))
end

--- The shader sources live in src/, so lde hands them to this script inside the
--- output directory. They are compiled on every build: lde only hashes src/,
--- lde.json and build.lua, so reusing a previously compiled .spv would ship a
--- stale shader after an edit, and shaders are tiny anyway.
---
--- `name` is the base of the .glsl file and the module it is written to, so
--- main.vert.glsl becomes shaders/main/vert.lua.
---@param name string e.g. "main"
---@param stage "vert" | "frag"
local function embedShader(name, stage)
	local file = name .. "." .. stage
	local glslPath = "shaders" .. sep .. file .. ".glsl"
	local sourcePath = glslPath

	if not isOpengl then
		sourcePath = file .. ".spv"
		build:sh(string.format('glslc -fshader-stage=%s "%s" -o "%s"', stage, glslPath, sourcePath))
	end

	local source = build:read(sourcePath)
	if not isOpengl then
		build:delete(sourcePath)
	end

	build:write("shaders" .. sep .. name .. sep .. stage .. ".lua", 'return "' .. toLuaLiteral(source) .. '"')
end

embedShader("main", "vert")
embedShader("main", "frag")
