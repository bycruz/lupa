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
		slot.overlayBindGroup = draw.overlayBindGroupFor(slot)
		slot.shadowBindGroups = {}
		for cascade = 1, draw.shadow.cascades do
			slot.shadowBindGroups[cascade] = draw.shadowBindGroupFor(slot, cascade)
		end
		frames[i] = slot
	end

	-- safety: the old buffers go after the waitIdle above, because frames in flight
	-- may still be reading them
	for _, old in ipairs(draw.frames) do
		old.bindGroup:destroy()
		old.overlayBindGroup:destroy()
		for cascade = 1, #old.shadowBindGroups do
			old.shadowBindGroups[cascade]:destroy()
			old.shadowTransforms[cascade]:destroy()
		end
		old.instanceBuffer:destroy()
		old.indirectBuffer:destroy()
		old.transformsBuffer:destroy()
		old.lightingBuffer:destroy()
		old.overlayTransformsBuffer:destroy()
		old.overlayLightingBuffer:destroy()
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

---@type fun(draw: lupa.Draw, encoder: hood.CommandEncoder, slot: lupa.draw.Slot, pipeline: hood.Pipeline, bindGroup: hood.BindGroup, firstRecord: number, recordCount: number)
local function recordPhase(draw, encoder, slot, pipeline, bindGroup, firstRecord, recordCount)
	-- safety: hood begins the render pass when the pipeline is bound, so every
	-- phase sets one even when it has nothing to draw
	encoder:setPipeline(pipeline)
	encoder:setBindGroup(0, bindGroup)

	if recordCount <= 0 then
		return
	end

	encoder:setVertexBuffer(0, draw.arena.vertexBuffer)
	encoder:setVertexBuffer(1, slot.instanceBuffer)
	encoder:setIndexBuffer(draw.arena.indexBuffer, "u32")
	encoder:drawIndexedIndirect(slot.indirectBuffer, firstRecord * records.drawStride, recordCount, records.drawStride)
end

---@param draw lupa.Draw
---@param encoder hood.CommandEncoder
---@param slot lupa.draw.Slot
---@param target hood.TextureView
---@param width number
---@param height number
local function recordFrame(draw, encoder, slot, target, width, height)
	local renderDesc = draw.renderDesc
	renderDesc.colorAttachments[1].texture = target
	encoder:beginRendering(renderDesc)
	encoder:setViewport(0, 0, width, height)

	recordPhase(draw, encoder, slot, draw.pipeline, slot.bindGroup, 0, draw.sceneRecords)

	if draw.overlayStart then
		recordPhase(draw, encoder, slot, draw.overlayPipeline, slot.overlayBindGroup,
			draw.sceneRecords, draw.drawRecordCount - draw.sceneRecords)
	end

	encoder:endRendering()
end

---@type fun(draw: lupa.Draw, encoder: hood.CommandEncoder, slot: lupa.draw.Slot, cascade: number)
local function recordShadow(draw, encoder, slot, cascade)
	local size = draw.shadow.size

	encoder:beginRendering(draw.shadowRenderDescs[cascade])
	encoder:setViewport(0, 0, size, size)

	-- safety: hood begins the render pass when the pipeline is bound
	encoder:setPipeline(draw.shadowPipeline)
	encoder:setBindGroup(0, slot.shadowBindGroups[cascade])

	-- safety: the first cascade covers a few chunks and the last one covers a view,
	-- so a game can name how many of the casters, nearest first, each cascade draws
	local casters = draw.casterCounts and draw.casterCounts[cascade] or (draw.shadowRecords or draw.sceneRecords)
	if casters > 0 then
		encoder:setVertexBuffer(0, draw.arena.vertexBuffer)
		encoder:setVertexBuffer(1, slot.instanceBuffer)
		encoder:setIndexBuffer(draw.arena.indexBuffer, "u32")
		encoder:drawIndexedIndirect(slot.indirectBuffer, 0, casters, records.drawStride)
	end

	encoder:endRendering()
end

---@class lupa.draw.Frame
---@field beginFrame fun(self: lupa.Draw)
---@field endShadowCasters fun(self: lupa.Draw, counts: number[]?)
---@field beginOverlay fun(self: lupa.Draw)
---@field endFrame fun(self: lupa.Draw)
---@field resize fun(self: lupa.Draw)
---@field captureFrame fun(self: lupa.Draw)
---@field capturePixels fun(self: lupa.Draw): number? width, number? height, string? pixels
---@field targetSize fun(self: lupa.Draw): number width, number height
local frame = {}

local methods = {}

---@type fun(self: lupa.Draw)
function methods.beginFrame(self)
	batch.reset(self)
	self.sceneRecords = 0
	self.overlayStart = nil
	self.shadowRecords = nil
	self.casterCounts = nil
end

---@type fun(self: lupa.Draw)
function methods.beginOverlay(self)
	assert(self.overlayStart == nil, "lupa: beginOverlay was already called this frame")

	self.sceneRecords = self.drawRecordCount
	self.overlayStart = {
		instances = self.instanceCount,
		records = self.drawRecordCount,
	}

	-- safety: without this the last scene draw and the first overlay draw would
	-- merge into one command spanning both phases
	batch.breakBatch(self)
end

---@type fun(self: lupa.Draw, counts: number[]?)
function methods.endShadowCasters(self, counts)
	assert(self.shadowRecords == nil, "lupa: endShadowCasters was already called this frame")

	if counts then
		for index = 1, self.shadowCascades do
			local count = counts[index]
			assert(type(count) == "number" and count >= 0,
				string.format("lupa: endShadowCasters wants how many records cascade %d draws", index))
			counts[index] = math.min(count, self.drawRecordCount)
		end
	end

	self.shadowRecords = self.drawRecordCount
	self.casterCounts = counts
end

---@type fun(self: lupa.Draw)
function methods.captureFrame(self)
	self.capturing = true
end

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
			self:resize()
			return
		end
	end

	-- safety: the meshes that changed this frame have to be in the arenas before the
	-- commands that read them are recorded and submitted
	self.uploads:flush()

	-- safety: capacity growth goes first, because it rebuilds the frame slots
	ensureGpuCapacity(self)

	-- safety: getCurrentTexture waited on this slot's fence, so the CPU may write
	-- its buffers
	local slot = self.frames[1]
	if not self.headless then
		slot = self.frames[self.swapchain.currentFrame or 1] or self.frames[1]
	end

	local encoder = self.headless and self.device:createCommandEncoder() or self.swapchain:createCommandEncoder()

	self.sceneRecords = self.overlayStart and self.overlayStart.records or self.drawRecordCount

	if self.shadowEnabled then
		view.refreshShadow(self, width, height)
	end

	if self.overlayStart then
		view.refreshOverlay(self, width, height)
		encoder:writeBuffer(slot.overlayTransformsBuffer, records.transformsSize, self.overlayTransforms)
		encoder:writeBuffer(slot.overlayLightingBuffer, records.lightingSize, self.overlayLighting)
	end

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

	-- safety: the shadow passes come first, because the frame pass samples their maps
	if self.shadowEnabled then
		for cascade = 1, self.shadowCascades do
			encoder:writeBuffer(slot.shadowTransforms[cascade], records.shadowTransformsSize,
				self.transforms.lightViewProj[cascade - 1])
			recordShadow(self, encoder, slot, cascade)
		end
	end

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
		-- safety: headless has nothing to present, so the command buffer is submitted on its own
		self.device.queue:submit(commandBuffer)
	else
		self.device.queue:submit(commandBuffer, self.swapchain)
		self.device.queue:present(self.swapchain)
	end
end

frame.methods = methods

return frame
