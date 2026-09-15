local ffi = require("ffi")

local batch = require("lupa.draw.batch")
local gpu = require("lupa.draw.gpu")
local records = require("lupa.draw.records")
local view = require("lupa.draw.view")

---@type ffi.cdata* unsigned byte pointer ctype, cached for ffi.cast
local bytePointer = ffi.typeof("uint8_t*")

---@type fun(draw: lupa.Draw, width: number, height: number)
local function ensureCaptureTarget(draw, width, height)
	if draw.captureTexture and draw.captureWidth == width and draw.captureHeight == height then
		return
	end

	if draw.captureTexture then
		draw.captureView:destroy()
		draw.captureTexture:destroy()
		draw.captureBuffer:destroy()
	end

	draw.captureWidth, draw.captureHeight = width, height
	local capture = gpu.createCapture(draw.device, width, height)
	draw.captureTexture, draw.captureView, draw.captureBuffer = capture.texture, capture.view, capture.buffer
end

--- Rebuild every frame slot at a new capacity, or for a new frame count.
---@type fun(draw: lupa.Draw, instanceCapacity: number, drawCapacity: number)
local function rebuildFrames(draw, instanceCapacity, drawCapacity)
	local device = draw.device
	local swapchain = draw.swapchain
	---@cast swapchain lupa.draw.Swapchain
	local frameCount = draw.headless and 1 or (swapchain.imageCount or 1)

	device.queue:waitIdle()

	local frames = {}
	for i = 1, frameCount do
		local slot = gpu.createSlot(device, instanceCapacity, drawCapacity)

		-- safety: a fresh uv scales buffer is zeroed, which would collapse every
		-- textured sample to one texel, so the scales are re-uploaded here
		gpu.upload(device, slot.uvScalesBuffer, gpu.uvScalesSize, draw.uvScales)
		slot.bindGroup = draw.bindGroupFor(slot)
		frames[i] = slot
	end

	-- safety: the old buffers go after the waitIdle above, because frames in flight
	-- may still be reading them
	for _, old in ipairs(draw.frames) do
		old.bindGroup:destroy()
		old.instanceBuffer:destroy()
		old.indirectBuffer:destroy()
		old.transformsBuffer:destroy()
		old.lightingBuffer:destroy()
		old.uvScalesBuffer:destroy()
	end

	draw.frames = frames
	draw.frameCount = frameCount
end

---@type fun(draw: lupa.Draw)
local function ensureGpuCapacity(draw)
	local slot = draw.frames[1]
	if draw.instanceCapacity <= slot.instanceCapacity and draw.drawRecordCapacity <= slot.drawCapacity then
		return
	end

	rebuildFrames(draw, draw.instanceCapacity, draw.drawRecordCapacity)
end

---@param draw lupa.Draw
---@param encoder hood.CommandEncoder
---@param slot table
---@param target hood.TextureView
---@param width number
---@param height number
local function recordFrame(draw, encoder, slot, target, width, height)
	local renderDesc = draw.renderDesc
	renderDesc.colorAttachments[1].texture = target
	encoder:beginRendering(renderDesc)
	encoder:setViewport(0, 0, width, height)

	-- safety: hood begins the render pass when the pipeline is bound, so an empty
	-- frame has to set it too
	encoder:setPipeline(draw.pipeline)
	encoder:setBindGroup(0, slot.bindGroup)

	if draw.drawRecordCount > 0 then
		encoder:setVertexBuffer(0, draw.arena.vertexBuffer)
		encoder:setVertexBuffer(1, slot.instanceBuffer)
		encoder:setIndexBuffer(draw.arena.indexBuffer, "u32")
		encoder:drawIndexedIndirect(slot.indirectBuffer, 0, draw.drawRecordCount, records.drawStride)
	end

	encoder:endRendering()
end

---@class lupa.draw.Frame
---@field beginFrame fun(self: lupa.Draw)
---@field endFrame fun(self: lupa.Draw)
---@field resize fun(self: lupa.Draw)
---@field captureFrame fun(self: lupa.Draw)
---@field capturePixels fun(self: lupa.Draw): number? width, number? height, string? pixels
---@field targetSize fun(self: lupa.Draw): number width, number height
local frame = {}

local methods = {}

--- Start a frame: the geometry of the previous one is dropped.
---@type fun(self: lupa.Draw)
function methods.beginFrame(self)
	batch.reset(self)
end

--- Render this frame to a readable image as well, as a second pass over its
--- geometry, for debugging and tests.
---@type fun(self: lupa.Draw)
function methods.captureFrame(self)
	self.capturing = true
end

--- The pixels of the last captured frame, or nothing when none is waiting.
---@type fun(self: lupa.Draw): number?, number?, string?
function methods.capturePixels(self)
	if not self.capturePending then
		return nil
	end

	-- safety: the copy has to finish before the buffer can be read
	self.device.queue:waitIdle()

	local buffer = self.captureBuffer
	buffer:mapAsync()
	local raw = ffi.cast(bytePointer, buffer:getMappedRange())
	local pixels = ffi.string(raw, self.captureWidth * self.captureHeight * 4)
	buffer:unmap()

	self.capturePending = false

	return self.captureWidth, self.captureHeight, pixels
end

--- Rebuild everything that depends on the surface size.
---@type fun(self: lupa.Draw)
function methods.resize(self)
	if self.headless then
		return
	end

	local device = self.device
	local swapchain = self.surface:configure(device, self.surfaceConfig, self.swapchain)

	local oldDepth, oldDepthView = self.depthBuffer, self.depthBufferView
	self.depthBuffer, self.depthBufferView = gpu.createDepth(device, swapchain.width, swapchain.height)
	self.swapchain = swapchain
	self.renderDesc.depthStencilAttachment.texture = self.depthBufferView

	-- safety: a reconfigured swapchain can have a different image count, and an
	-- index past the end of the frame array would silently reuse slot 1
	if (swapchain.imageCount or 1) ~= self.frameCount then
		rebuildFrames(self, self.instanceCapacity, self.drawRecordCapacity)
	end

	self.projWidth, self.projHeight = nil, nil
	if self.camera then
		self:setCamera(self.camera)
	end

	-- safety: the configure above waits for the queue, so the old depth target is
	-- no longer in use
	oldDepthView:destroy()
	oldDepth:destroy()
end

--- The size of whatever the frame is rendered into.
---@type fun(self: lupa.Draw): number, number
function methods.targetSize(self)
	if self.headless then
		-- safety: headless never resizes, so this is the size of every frame
		return self.targetWidth, self.targetHeight
	end

	return self.window.width, self.window.height
end

---@type fun(self: lupa.Draw)
function methods.endFrame(self)
	local width, height = self:targetSize()
	view.refreshProjection(self, width, height)

	local texture
	if not self.headless then
		texture = self.swapchain:getCurrentTexture()
		if not texture then
			-- safety: rebuild the swapchain and skip this frame
			self:resize()
			return
		end
	end

	-- Growth first, because it waits for the queue to drain.
	ensureGpuCapacity(self)

	-- safety: getCurrentTexture waited on this slot's fence, so the CPU may write
	-- its buffers
	local slot = self.frames[1]
	if not self.headless then
		slot = self.frames[self.swapchain.currentFrame or 1] or self.frames[1]
	end

	local encoder = self.headless and self.device:createCommandEncoder() or self.swapchain:createCommandEncoder()

	encoder:writeBuffer(slot.transformsBuffer, records.transformsSize, self.transforms)
	encoder:writeBuffer(slot.lightingBuffer, records.lightingSize, self.lighting)
	if self.instanceCount > 0 then
		encoder:writeBuffer(slot.instanceBuffer, records.instanceStride * self.instanceCount, self.instances)
		encoder:writeBuffer(slot.indirectBuffer, records.drawStride * self.drawRecordCount, self.drawRecords)
	end

	-- safety: a texture added earlier changed the scales for every slot, so slots
	-- compare revisions rather than a flag one frame would clear for all
	if slot.uvScalesRevision ~= self.uvScalesRevision then
		encoder:writeBuffer(slot.uvScalesBuffer, gpu.uvScalesSize, self.uvScales)
		slot.uvScalesRevision = self.uvScalesRevision
	end

	-- Headless always renders into the capture target; a window renders into it
	-- when a capture was asked for.
	local capturing = self.headless or self.capturing

	if not self.headless then
		recordFrame(self, encoder, slot, texture:createView(self.emptyViewDesc), width, height)
	end

	if capturing then
		local capWidth, capHeight = self.targetWidth, self.targetHeight
		if not self.headless then
			capWidth, capHeight = self.swapchain.width, self.swapchain.height
		end

		ensureCaptureTarget(self, capWidth, capHeight)
		recordFrame(self, encoder, slot, self.captureView, width, height)

		encoder:copyTextureToBuffer(
			{ texture = self.captureTexture },
			{ buffer = self.captureBuffer, bytesPerRow = capWidth * 4 },
			{ width = capWidth, height = capHeight })

		self.capturing = false
		self.capturePending = true
	end

	local commandBuffer = encoder:finish()

	if self.headless then
		-- safety: headless has nothing to present, so the command buffer is
		-- submitted on its own
		self.device.queue:submit(commandBuffer)
	else
		self.device.queue:submit(commandBuffer, self.swapchain)
		self.device.queue:present(self.swapchain)
	end
end

frame.methods = methods

return frame
