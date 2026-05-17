local outputDir = os.getenv("LDE_OUTPUT_DIR")

local pathSep = string.sub(package.config, 1, 1)

---@type string
local packageSourceDir = debug.getinfo(1, "S").source:sub(2):match("(.*)" .. pathSep)

---@param stage "vert" | "frag" | "comp"
---@param glslPath string
---@param outputPath string
local function glslToSpirv(stage, glslPath, outputPath)
	local command = string.format("glslc -fshader-stage=%s %s -o %s", stage, glslPath, outputPath)

	local result = os.execute(command)
	if result ~= 0 then
		error("Failed to compile GLSL shader: " .. glslPath)
	end
end

---@param path string
local function exists(path)
	local handle = io.open(path, "r")
	if handle then
		handle:close()
		return true
	end

	return false
end

---@param spvPath string
---@param luaPath string
local function spirvToLua(spvPath, luaPath)
	local f = assert(io.open(spvPath, "rb"))
	local data = f:read("*a")
	f:close()

	local escaped = data:gsub(".", function(c)
		return string.format("\\%d", c:byte())
	end)

	local out = assert(io.open(luaPath, "w"))
	out:write('return "' .. escaped .. '"\n')
	out:close()
end

---@param glslPath string
---@param luaPath string
local function glslToLua(glslPath, luaPath)
	local f = assert(io.open(glslPath, "r"))
	local source = f:read("*a")
	f:close()

	local escaped = source:gsub("\\", "\\\\")
		:gsub('"', '\\"')
		:gsub("\n", "\\n")

	local out = assert(io.open(luaPath, "w"))
	out:write('return "' .. escaped .. '"\n')
	out:close()
end

---@return boolean
local function useOpenglBackend()
	return os.getenv("BACKEND") == "opengl"
end

---@param path string
local function mkdir(path)
	if jit.os == "Windows" then
		os.execute(string.format('mkdir "%s"', path))
	else
		os.execute(string.format("mkdir -p '%s'", path))
	end
end

local shaders = {
	{ name = "main", stage = "vert" },
	{ name = "main", stage = "frag" }
}

local backendIsOpengl = useOpenglBackend()

for _, shader in ipairs(shaders) do
	local glslPath = string.format("%s/shaders/%s.%s.glsl", packageSourceDir, shader.name, shader.stage)
	local shaderOutDir = string.format("%s/shaders/%s", outputDir, shader.name)

	if not exists(shaderOutDir) then
		mkdir(shaderOutDir)
	end

	if backendIsOpengl then
		print(string.format("Writing GLSL %s shader directly...", shader.stage))
		glslToLua(glslPath, string.format("%s/%s.lua", shaderOutDir, shader.stage))
	else
		local spvPath = string.format("%s/shaders/%s.%s.spv", packageSourceDir, shader.name, shader.stage)

		if not exists(spvPath) then
			print(string.format("SPIR-V %s shader not found, compiling GLSL to SPIR-V...", shader.stage))
			glslToSpirv(shader.stage, glslPath, spvPath)
		end

		spirvToLua(spvPath, string.format("%s/%s.lua", shaderOutDir, shader.stage))
	end
end
