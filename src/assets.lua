---@class lupa.Assets
local Assets = {}
Assets.__index = Assets

function Assets.new()
	return setmetatable({}, Assets)
end

return Assets
