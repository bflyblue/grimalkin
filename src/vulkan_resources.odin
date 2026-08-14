package main

import "core:fmt"
import "core:mem"
import "core:slice"
import vk "vendor:vulkan"

find_memory_type :: proc(
	renderer: ^Vulkan_Renderer,
	type_bits: u32,
	required: vk.MemoryPropertyFlags,
) -> u32 {
	properties: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(renderer.physical_device, &properties)
	for index := u32(0); index < properties.memoryTypeCount; index += 1 {
		available := properties.memoryTypes[index].propertyFlags
		if type_bits & (u32(1) << index) != 0 && (available & required) == required {
			return index
		}
	}
	fmt.panicf("no Vulkan memory type satisfies %v", required)
}

create_buffer :: proc(
	renderer: ^Vulkan_Renderer,
	size: vk.DeviceSize,
	usage: vk.BufferUsageFlags,
	properties: vk.MemoryPropertyFlags,
	map_memory: bool,
) -> Gpu_Buffer {
	buffer := Gpu_Buffer {
		size = size,
	}
	create_info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = size,
		usage       = usage,
		sharingMode = .EXCLUSIVE,
	}
	vk_must(vk.CreateBuffer(renderer.device, &create_info, nil, &buffer.handle), "creating a buffer")

	requirements: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(renderer.device, buffer.handle, &requirements)
	allocate_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = requirements.size,
		memoryTypeIndex = find_memory_type(renderer, requirements.memoryTypeBits, properties),
	}
	vk_must(
		vk.AllocateMemory(renderer.device, &allocate_info, nil, &buffer.memory),
		"allocating buffer memory",
	)
	vk_must(
		vk.BindBufferMemory(renderer.device, buffer.handle, buffer.memory, 0),
		"binding buffer memory",
	)
	if map_memory {
		vk_must(
			vk.MapMemory(renderer.device, buffer.memory, 0, size, {}, &buffer.mapped),
			"mapping buffer memory",
		)
	}
	return buffer
}

destroy_buffer :: proc(device: vk.Device, buffer: ^Gpu_Buffer) {
	if buffer.mapped != nil {
		vk.UnmapMemory(device, buffer.memory)
	}
	if buffer.handle != 0 {
		vk.DestroyBuffer(device, buffer.handle, nil)
	}
	if buffer.memory != 0 {
		vk.FreeMemory(device, buffer.memory, nil)
	}
	buffer^ = {}
}

write_mapped_buffer :: proc(buffer: ^Gpu_Buffer, data: []u8) {
	write_mapped_buffer_range(buffer, 0, data)
}

write_mapped_buffer_range :: proc(buffer: ^Gpu_Buffer, offset: vk.DeviceSize, data: []u8) {
	if offset > buffer.size || u64(len(data)) > u64(buffer.size - offset) {
		fmt.panicf(
			"attempted to write %d bytes at offset %d to a %d-byte Vulkan buffer",
			len(data),
			offset,
			buffer.size,
		)
	}
	if len(data) > 0 {
		destination := rawptr(uintptr(buffer.mapped) + uintptr(offset))
		mem.copy(destination, raw_data(data), len(data))
	}
}

texture_vulkan_format :: proc(resource: ^Texture_Resource) -> vk.Format {
	if resource.format == .Mask_R8 do return .R8_UNORM
	return resource.encoding == .SRGB ? .R8G8B8A8_SRGB : .R8G8B8A8_UNORM
}

create_texture_image :: proc(app: ^Grimalkin_App, resource: ^Texture_Resource) -> Gpu_Texture_Image {
	texture := Gpu_Texture_Image {
		slot_generation = resource.slot_generation,
		width      = resource.width,
		height     = resource.height,
		layers     = resource.layers,
		format     = resource.format,
		encoding   = resource.encoding,
		alpha_mode = resource.alpha_mode,
		filter     = resource.filter,
		layout     = .UNDEFINED,
	}
	vulkan_format := texture_vulkan_format(resource)
	image_info := vk.ImageCreateInfo {
		sType = .IMAGE_CREATE_INFO,
		imageType = .D2,
		format = vulkan_format,
		extent = {width = resource.width, height = resource.height, depth = 1},
		mipLevels = 1,
		arrayLayers = resource.layers,
		samples = {._1},
		tiling = .OPTIMAL,
		usage = {.TRANSFER_SRC, .TRANSFER_DST, .SAMPLED},
		sharingMode = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	vk_must(
		vk.CreateImage(app.device, &image_info, nil, &texture.image),
		"creating a texture resource",
	)

	requirements: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(app.device, texture.image, &requirements)
	allocate_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = requirements.size,
		memoryTypeIndex = find_memory_type(&app.renderer, requirements.memoryTypeBits, {.DEVICE_LOCAL}),
	}
	vk_must(
		vk.AllocateMemory(app.device, &allocate_info, nil, &texture.memory),
		"allocating texture memory",
	)
	vk_must(
		vk.BindImageMemory(app.device, texture.image, texture.memory, 0),
		"binding texture memory",
	)

	view_info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = texture.image,
		viewType = .D2_ARRAY,
		format = vulkan_format,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = resource.layers},
	}
	vk_must(
		vk.CreateImageView(app.device, &view_info, nil, &texture.view),
		"creating a texture-array view",
	)

	filter: vk.Filter = .NEAREST
	if resource.filter == .Linear {
		filter = .LINEAR
	}
	sampler_info := vk.SamplerCreateInfo {
		sType        = .SAMPLER_CREATE_INFO,
		magFilter    = filter,
		minFilter    = filter,
		mipmapMode   = .NEAREST,
		addressModeU = .CLAMP_TO_EDGE,
		addressModeV = .CLAMP_TO_EDGE,
		addressModeW = .CLAMP_TO_EDGE,
		maxLod       = 0,
	}
	vk_must(
		vk.CreateSampler(app.device, &sampler_info, nil, &texture.sampler),
		"creating a texture sampler",
	)
	return texture
}

destroy_texture_image :: proc(device: vk.Device, texture: ^Gpu_Texture_Image) {
	if texture.sampler != 0 {
		vk.DestroySampler(device, texture.sampler, nil)
	}
	if texture.view != 0 {
		vk.DestroyImageView(device, texture.view, nil)
	}
	if texture.image != 0 {
		vk.DestroyImage(device, texture.image, nil)
	}
	if texture.memory != 0 {
		vk.FreeMemory(device, texture.memory, nil)
	}
	texture^ = {}
}

destroy_texture_images :: proc(device: vk.Device, textures: []Gpu_Texture_Image) {
	for &texture in textures do destroy_texture_image(device, &texture)
}

create_descriptor_sets :: proc(app: ^Grimalkin_App) {
	set_count := u32(len(app.frames) * 3)
	pool_sizes := [2]vk.DescriptorPoolSize {
		{type = .STORAGE_BUFFER, descriptorCount = set_count * 3},
		{type = .COMBINED_IMAGE_SAMPLER, descriptorCount = app.texture_capacity * set_count},
	}
	pool_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		maxSets       = set_count,
		poolSizeCount = u32(len(pool_sizes)),
		pPoolSizes    = &pool_sizes[0],
	}
	vk_must(
		vk.CreateDescriptorPool(app.device, &pool_info, nil, &app.descriptor_pool),
		"creating the text descriptor pool",
	)
	descriptor_counts := make([]u32, int(set_count), context.temp_allocator)
	for &count in descriptor_counts do count = app.texture_capacity
	variable_count := vk.DescriptorSetVariableDescriptorCountAllocateInfo {
		sType              = .DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO,
		descriptorSetCount = set_count,
		pDescriptorCounts  = raw_data(descriptor_counts),
	}
	layouts := make([]vk.DescriptorSetLayout, int(set_count), context.temp_allocator)
	for &layout in layouts do layout = app.descriptor_layout
	sets := make([]vk.DescriptorSet, int(set_count), context.temp_allocator)
	allocate_info := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		pNext              = &variable_count,
		descriptorPool     = app.descriptor_pool,
		descriptorSetCount = set_count,
		pSetLayouts        = raw_data(layouts),
	}
	vk_must(
		vk.AllocateDescriptorSets(app.device, &allocate_info, raw_data(sets)),
		"allocating text descriptor sets",
	)
	for &frame, index in app.frames {
		frame.descriptor_set = sets[index * 3]
		frame.osd_descriptor_set = sets[index * 3 + 1]
		frame.selection_descriptor_set = sets[index * 3 + 2]
	}
}

update_selection_descriptor_set :: proc(app: ^Grimalkin_App, frame: ^Frame_Context) {
	if frame.selection_descriptor_set == 0 || frame.selection_mask_buffer.handle == 0 do return
	cell_info := vk.DescriptorBufferInfo{buffer = frame.cell_buffer.handle, range = frame.cell_buffer.size}
	visual_info := vk.DescriptorBufferInfo{buffer = frame.visual_buffer.handle, range = frame.visual_buffer.size}
	mask_info := vk.DescriptorBufferInfo{buffer = frame.selection_mask_buffer.handle, range = frame.selection_mask_buffer.size}
	writes := [3]vk.WriteDescriptorSet {
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = frame.selection_descriptor_set,
			dstBinding = 0,
			descriptorCount = 1,
			descriptorType = .STORAGE_BUFFER,
			pBufferInfo = &cell_info,
		},
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = frame.selection_descriptor_set,
			dstBinding = 1,
			descriptorCount = 1,
			descriptorType = .STORAGE_BUFFER,
			pBufferInfo = &visual_info,
		},
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = frame.selection_descriptor_set,
			dstBinding = 2,
			descriptorCount = 1,
			descriptorType = .STORAGE_BUFFER,
			pBufferInfo = &mask_info,
		},
	}
	vk.UpdateDescriptorSets(app.device, u32(len(writes)), &writes[0], 0, nil)
}

update_descriptor_set :: proc(
	app: ^Grimalkin_App,
	frame: ^Frame_Context,
	descriptor_set: vk.DescriptorSet,
	cell_buffer: ^Gpu_Buffer,
) {
	cell_info := vk.DescriptorBufferInfo {
		buffer = cell_buffer.handle,
		range  = cell_buffer.size,
	}
	visual_info := vk.DescriptorBufferInfo {
		buffer = frame.visual_buffer.handle,
		range  = frame.visual_buffer.size,
	}
	decoration_info := vk.DescriptorBufferInfo {
		buffer = frame.decoration_buffer.handle,
		range  = frame.decoration_buffer.size,
	}
	image_infos := make([]vk.DescriptorImageInfo, len(app.texture_images), context.temp_allocator)
	writes := make([]vk.WriteDescriptorSet, 3 + len(app.texture_images), context.temp_allocator)
	writes[0] = {
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = descriptor_set,
			dstBinding = 0,
			descriptorCount = 1,
			descriptorType = .STORAGE_BUFFER,
			pBufferInfo = &cell_info,
		}
	writes[1] = {
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = descriptor_set,
			dstBinding = 1,
			descriptorCount = 1,
			descriptorType = .STORAGE_BUFFER,
			pBufferInfo = &visual_info,
		}
	writes[2] = {
		sType = .WRITE_DESCRIPTOR_SET,
		dstSet = descriptor_set,
		dstBinding = 2,
		descriptorCount = 1,
		descriptorType = .STORAGE_BUFFER,
		pBufferInfo = &decoration_info,
	}
	write_count := 3
	for texture, index in app.texture_images {
		if texture.view == 0 do continue
		image_infos[index] = {
			sampler     = texture.sampler,
			imageView   = texture.view,
			imageLayout = .SHADER_READ_ONLY_OPTIMAL,
		}
		writes[write_count] = {
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = descriptor_set,
			dstBinding      = 3,
			dstArrayElement = u32(index),
			descriptorCount = 1,
			descriptorType  = .COMBINED_IMAGE_SAMPLER,
			pImageInfo      = &image_infos[index],
		}
		write_count += 1
	}
	vk.UpdateDescriptorSets(app.device, u32(write_count), &writes[0], 0, nil)
}

update_text_descriptors :: proc(app: ^Grimalkin_App, frame: ^Frame_Context) {
	update_descriptor_set(app, frame, frame.descriptor_set, &frame.cell_buffer)
	if frame.osd_descriptor_set != 0 do update_descriptor_set(app, frame, frame.osd_descriptor_set, &frame.osd_cell_buffer)
	update_selection_descriptor_set(app, frame)
}

ensure_mapped_buffer_capacity :: proc(
	app: ^Grimalkin_App,
	buffer: ^Gpu_Buffer,
	capacity: ^int,
	required, minimum, element_size: int,
	usage: vk.BufferUsageFlags,
) -> bool {
	if element_size <= 0 do fmt.panicf("mapped Vulkan buffer element size must be positive")
	current := int(buffer.size) / element_size
	if capacity != nil do current = capacity^
	if required <= current do return false

	next := max(minimum, max(1, current))
	for next < required {
		if next > max(int) / 2 {
			next = required
			break
		}
		next *= 2
	}
	if next > max(int) / element_size do fmt.panicf("mapped Vulkan buffer size overflow")
	destroy_buffer(app.device, buffer)
	buffer^ = create_buffer(
		&app.renderer,
		vk.DeviceSize(next * element_size),
		usage,
		{.HOST_VISIBLE, .HOST_COHERENT},
		true,
	)
	if capacity != nil do capacity^ = next
	return true
}

ensure_visual_buffer :: proc(app: ^Grimalkin_App, frame: ^Frame_Context) -> bool {
	recreated := ensure_mapped_buffer_capacity(
		app,
		&frame.visual_buffer,
		&frame.visual_capacity,
		len(app.demo.resources.visuals.records),
		256,
		size_of(Gpu_Visual_Record),
		{.STORAGE_BUFFER},
	)
	if !recreated do return false
	frame.visuals_uploaded = 0
	if frame.descriptor_set != 0 do update_text_descriptors(app, frame)
	return true
}

ensure_cell_buffer :: proc(app: ^Grimalkin_App, frame: ^Frame_Context) -> bool {
	recreated := ensure_mapped_buffer_capacity(
		app,
		&frame.cell_buffer,
		&frame.cell_capacity,
		len(app.demo.grid.cells),
		GRID_CELL_COUNT,
		size_of(Gpu_Cell),
		{.STORAGE_BUFFER},
	)
	if !recreated do return false
	if frame.descriptor_set != 0 do update_text_descriptors(app, frame)
	return true
}

ensure_decoration_buffer :: proc(app: ^Grimalkin_App, frame: ^Frame_Context) -> bool {
	recreated := ensure_mapped_buffer_capacity(
		app,
		&frame.decoration_buffer,
		&frame.decoration_capacity,
		max(1, len(app.demo.grid.decorations)),
		GRID_CELL_COUNT,
		size_of(u32),
		{.STORAGE_BUFFER},
	)
	if !recreated do return false
	if frame.descriptor_set != 0 do update_text_descriptors(app, frame)
	return true
}

ensure_osd_cell_buffer :: proc(app: ^Grimalkin_App, frame: ^Frame_Context) -> bool {
	recreated := ensure_mapped_buffer_capacity(
		app,
		&frame.osd_cell_buffer,
		&frame.osd_cell_capacity,
		max(1, len(app.osd.cells)),
		512,
		size_of(Gpu_Cell),
		{.STORAGE_BUFFER},
	)
	if !recreated do return false
	if frame.osd_descriptor_set != 0 do update_text_descriptors(app, frame)
	return true
}

ensure_selection_mask_buffer :: proc(app: ^Grimalkin_App, frame: ^Frame_Context) -> bool {
	recreated := ensure_mapped_buffer_capacity(
		app,
		&frame.selection_mask_buffer,
		&frame.selection_mask_capacity,
		max(1, len(app.selection.mask)),
		256,
		size_of(u32),
		{.STORAGE_BUFFER},
	)
	if !recreated do return false
	if frame.selection_descriptor_set != 0 do update_selection_descriptor_set(app, frame)
	return true
}

ensure_staging_buffer :: proc(app: ^Grimalkin_App, required_size: int) {
	_ = ensure_mapped_buffer_capacity(
		app,
		&app.staging_buffer,
		nil,
		required_size,
		4096,
		1,
		{.TRANSFER_SRC},
	)
}

begin_one_time_commands :: proc(app: ^Grimalkin_App) {
	vk_must(
		vk.WaitForFences(app.device, 1, &app.upload_fence, true, max(u64)),
		"waiting to reuse the texture-upload command buffer",
	)
	vk_must(vk.ResetFences(app.device, 1, &app.upload_fence), "resetting the texture-upload fence")
	vk_must(vk.ResetCommandBuffer(app.command_buffer, {}), "resetting the transfer command buffer")
	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	vk_must(vk.BeginCommandBuffer(app.command_buffer, &begin_info), "beginning transfer commands")
}

end_one_time_commands :: proc(app: ^Grimalkin_App) {
	vk_must(vk.EndCommandBuffer(app.command_buffer), "ending transfer commands")
	submit_info := vk.SubmitInfo {
		sType              = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers    = &app.command_buffer,
	}
	vk_must(
		vk.QueueSubmit(app.graphics_queue, 1, &submit_info, app.upload_fence),
		"submitting transfer commands",
	)
	vk_must(
		vk.WaitForFences(app.device, 1, &app.upload_fence, true, max(u64)),
		"waiting for transfer commands",
	)
}

transition_texture :: proc(
	command_buffer: vk.CommandBuffer,
	texture: ^Gpu_Texture_Image,
	new_layout: vk.ImageLayout,
) {
	old_layout := texture.layout
	if old_layout == new_layout {
		return
	}
	source_stage := vk.PipelineStageFlags{.TOP_OF_PIPE}
	destination_stage := vk.PipelineStageFlags{.TRANSFER}
	source_access := vk.AccessFlags{}
	destination_access := vk.AccessFlags{.TRANSFER_WRITE}

	if old_layout == .SHADER_READ_ONLY_OPTIMAL && new_layout == .TRANSFER_DST_OPTIMAL {
		source_stage = {.FRAGMENT_SHADER}
		destination_stage = {.TRANSFER}
		source_access = {.SHADER_READ}
		destination_access = {.TRANSFER_WRITE}
	} else if old_layout == .SHADER_READ_ONLY_OPTIMAL && new_layout == .TRANSFER_SRC_OPTIMAL {
		source_stage = {.FRAGMENT_SHADER}
		destination_stage = {.TRANSFER}
		source_access = {.SHADER_READ}
		destination_access = {.TRANSFER_READ}
	} else if old_layout == .TRANSFER_DST_OPTIMAL && new_layout == .SHADER_READ_ONLY_OPTIMAL {
		source_stage = {.TRANSFER}
		destination_stage = {.FRAGMENT_SHADER}
		source_access = {.TRANSFER_WRITE}
		destination_access = {.SHADER_READ}
	} else {
		if old_layout != .UNDEFINED || new_layout != .TRANSFER_DST_OPTIMAL {
			fmt.panicf("unsupported texture layout transition: %v -> %v", old_layout, new_layout)
		}
	}

	barrier := vk.ImageMemoryBarrier {
		sType = .IMAGE_MEMORY_BARRIER,
		srcAccessMask = source_access,
		dstAccessMask = destination_access,
		oldLayout = old_layout,
		newLayout = new_layout,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = texture.image,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = texture.layers},
	}
	vk.CmdPipelineBarrier(
		command_buffer,
		source_stage,
		destination_stage,
		{},
		0,
		nil,
		0,
		nil,
		1,
		&barrier,
	)
	texture.layout = new_layout
}

gpu_texture_matches :: proc(texture: ^Gpu_Texture_Image, resource: ^Texture_Resource) -> bool {
	return(
		texture.image != 0 &&
		texture.slot_generation == resource.slot_generation &&
		texture.width == resource.width &&
		texture.height == resource.height &&
		texture.layers == resource.layers &&
		texture.format == resource.format &&
		texture.encoding == resource.encoding &&
		texture.alpha_mode == resource.alpha_mode &&
		texture.filter == resource.filter \
	)
}

upload_texture_resource :: proc(app: ^Grimalkin_App, resource: ^Texture_Resource) -> bool {
	texture := &app.texture_images[resource.id]
	recreated := false
	growing :=
		texture.image != 0 &&
		texture.width == resource.width &&
		texture.height == resource.height &&
		texture.layers < resource.layers &&
		texture.layers == resource.grew_from_layers &&
		texture.format == resource.format &&
		texture.encoding == resource.encoding &&
		texture.alpha_mode == resource.alpha_mode &&
		texture.filter == resource.filter
	old_texture := Gpu_Texture_Image{}
	if !gpu_texture_matches(texture, resource) {
		if growing {
			old_texture = texture^
		} else if texture.image != 0 {
			destroy_texture_image(app.device, texture)
			resource.full_upload = true
		}
		texture^ = create_texture_image(app, resource)
		recreated = true
	}
	if !resource.full_upload && len(resource.pending_uploads) == 0 && !growing {
		return recreated
	}

	bpp := texture_bytes_per_pixel(resource.format)
	total_bytes := 0
	region_count := len(resource.pending_uploads)
	if resource.full_upload {
		total_bytes = len(resource.pixels)
		region_count = 1
	} else {
		for pending in resource.pending_uploads {
			pending_bytes, pending_bytes_ok := texture_byte_count(
				pending.placement.width,
				pending.placement.height,
				1,
				bpp,
			)
			if !pending_bytes_ok || total_bytes > max(int) - 3 do return false
			total_bytes = (total_bytes + 3) / 4 * 4
			if total_bytes > max(int) - pending_bytes do return false
			total_bytes += pending_bytes
		}
	}
	if total_bytes > 0 {
		ensure_staging_buffer(app, total_bytes)
	}
	regions := make([]vk.BufferImageCopy, region_count, context.temp_allocator)
	if resource.full_upload {
		mem.copy(app.staging_buffer.mapped, raw_data(resource.pixels), len(resource.pixels))
		regions[0] = {
			imageSubresource = {
				aspectMask = {.COLOR},
				mipLevel = 0,
				baseArrayLayer = 0,
				layerCount = resource.layers,
			},
			imageExtent = {width = resource.width, height = resource.height, depth = 1},
		}
	} else {
		cursor := 0
		layer_stride, layer_stride_ok := texture_byte_count(resource.width, resource.height, 1, bpp)
		if !layer_stride_ok do return false
		for pending, index in resource.pending_uploads {
			cursor = (cursor + 3) / 4 * 4
			placement := pending.placement
			regions[index] = {
				bufferOffset = vk.DeviceSize(cursor),
				imageSubresource = {
					aspectMask = {.COLOR},
					mipLevel = 0,
					baseArrayLayer = placement.layer,
					layerCount = 1,
				},
				imageOffset = {x = i32(placement.x), y = i32(placement.y)},
				imageExtent = {width = placement.width, height = placement.height, depth = 1},
			}
			for row := u32(0); row < placement.height; row += 1 {
				source_offset :=
					int(placement.layer) * layer_stride +
					int((u64(placement.y) + u64(row)) * u64(resource.width) + u64(placement.x)) * bpp
				row_size := int(placement.width) * bpp
				mem.copy(
					rawptr(uintptr(app.staging_buffer.mapped) + uintptr(cursor)),
					raw_data(resource.pixels[source_offset:source_offset + row_size]),
					row_size,
				)
				cursor += row_size
			}
		}
	}

	begin_one_time_commands(app)
	if growing {
		transition_texture(app.command_buffer, &old_texture, .TRANSFER_SRC_OPTIMAL)
	}
	transition_texture(app.command_buffer, texture, .TRANSFER_DST_OPTIMAL)
	if growing {
		copy_region := vk.ImageCopy {
			srcSubresource = {aspectMask = {.COLOR}, layerCount = old_texture.layers},
			dstSubresource = {aspectMask = {.COLOR}, layerCount = old_texture.layers},
			extent = {width = resource.width, height = resource.height, depth = 1},
		}
		vk.CmdCopyImage(
			app.command_buffer,
			old_texture.image,
			.TRANSFER_SRC_OPTIMAL,
			texture.image,
			.TRANSFER_DST_OPTIMAL,
			1,
			&copy_region,
		)
	}
	if len(regions) > 0 {
		vk.CmdCopyBufferToImage(
			app.command_buffer,
			app.staging_buffer.handle,
			texture.image,
			.TRANSFER_DST_OPTIMAL,
			u32(len(regions)),
			raw_data(regions),
		)
	}
	transition_texture(app.command_buffer, texture, .SHADER_READ_ONLY_OPTIMAL)
	end_one_time_commands(app)
	if growing {
		destroy_texture_image(app.device, &old_texture)
	}
	resource.full_upload = false
	resource.grew_from_layers = 0
	clear(&resource.pending_uploads)
	return recreated
}

sync_texture_resources :: proc(app: ^Grimalkin_App, frame: ^Frame_Context) {
	resource_count := len(app.demo.resources.textures.resources)
	if resource_count > int(app.texture_capacity) {
		fmt.panicf(
			"renderer needs %d textures; descriptor array capacity is %d",
			resource_count,
			app.texture_capacity,
		)
	}
	for len(app.texture_images) < resource_count {
		append(&app.texture_images, Gpu_Texture_Image{})
	}
	mutation_pending := false
	for resource, index in app.demo.resources.textures.resources {
		if resource == nil {
			mutation_pending = mutation_pending || app.texture_images[index].image != 0
		} else {
			mutation_pending =
				mutation_pending || !gpu_texture_matches(&app.texture_images[index], resource) ||
				resource.full_upload || len(resource.pending_uploads) > 0
		}
	}
	if mutation_pending {
		for &pending_frame in app.frames {
			if pending_frame.in_flight != 0 {
				vk_must(
					vk.WaitForFences(app.device, 1, &pending_frame.in_flight, true, max(u64)),
					"waiting before mutating shared textures",
				)
			}
		}
	}
	descriptors_changed := false
	for resource, index in app.demo.resources.textures.resources {
		if resource == nil {
			if app.texture_images[index].image != 0 {
				destroy_texture_image(app.device, &app.texture_images[index])
				descriptors_changed = true
			}
			continue
		}
		descriptors_changed = upload_texture_resource(app, resource) || descriptors_changed
	}
	if frame.descriptor_set != 0 && (descriptors_changed || len(app.texture_images) > 0) {
		update_text_descriptors(app, frame)
	}
}

flush_text_resources :: proc(app: ^Grimalkin_App, frame: ^Frame_Context) -> Gpu_Upload_Stats {
	stats := Gpu_Upload_Stats{}
	cell_recreated := ensure_cell_buffer(app, frame)
	decoration_recreated := ensure_decoration_buffer(app, frame)
	visual_recreated := ensure_visual_buffer(app, frame)
	ranges := display_grid_dirty_ranges(&app.demo.grid, context.temp_allocator)
	if len(ranges) > 0 do app.grid_generation += 1
	grid_changed :=
		cell_recreated || decoration_recreated || frame.grid_generation != app.grid_generation
	if grid_changed {
		bytes := slice.reinterpret([]u8, app.demo.grid.cells)
		write_mapped_buffer(&frame.cell_buffer, bytes)
		stats.cell_bytes = u64(len(bytes))
		bytes = slice.reinterpret([]u8, app.demo.grid.decorations)
		write_mapped_buffer(&frame.decoration_buffer, bytes)
		stats.cell_bytes += u64(len(bytes))
		frame.grid_generation = app.grid_generation
	}
	display_grid_clear_dirty(&app.demo.grid)

	visuals := app.demo.resources.visuals.records[:]
	if visual_recreated || frame.visual_generation != app.demo.resources.visuals.revision {
		bytes := slice.reinterpret([]u8, visuals)
		write_mapped_buffer(&frame.visual_buffer, bytes)
		stats.visual_bytes = u64(len(bytes))
		frame.visuals_uploaded = len(visuals)
		frame.visual_generation = app.demo.resources.visuals.revision
	}
	sync_texture_resources(app, frame)
	osd_recreated := ensure_osd_cell_buffer(app, frame)
	if app.osd.dirty do app.osd_generation += 1
	if osd_recreated || frame.osd_generation != app.osd_generation {
		if len(app.osd.cells) > 0 do write_mapped_buffer(&frame.osd_cell_buffer, slice.reinterpret([]u8, app.osd.cells))
		frame.osd_generation = app.osd_generation
	}
	selection_recreated := ensure_selection_mask_buffer(app, frame)
	if selection_recreated || frame.selection_generation != app.selection.mask_generation {
		if len(app.selection.mask) > 0 {
			write_mapped_buffer(&frame.selection_mask_buffer, slice.reinterpret([]u8, app.selection.mask))
		}
		frame.selection_generation = app.selection.mask_generation
	}
	app.osd.dirty = false
	return stats
}

create_text_resources :: proc(app: ^Grimalkin_App) {
	for &frame in app.frames {
		_ = ensure_cell_buffer(app, &frame)
		_ = ensure_decoration_buffer(app, &frame)
		_ = ensure_osd_cell_buffer(app, &frame)
		_ = ensure_selection_mask_buffer(app, &frame)
		_ = ensure_visual_buffer(app, &frame)
		sync_texture_resources(app, &frame)
	}
	create_descriptor_sets(app)
	if len(display_grid_dirty_ranges(&app.demo.grid, context.temp_allocator)) > 0 do app.grid_generation += 1
	if app.osd.dirty do app.osd_generation += 1
	for &frame in app.frames {
		update_text_descriptors(app, &frame)
		// These buffers were just allocated above. Their old generation values
		// may numerically match a newly rebuilt cache, so generation comparisons
		// cannot establish that they contain data yet. Initialize every frame
		// unconditionally before incremental uploads resume.
		write_mapped_buffer(&frame.cell_buffer, slice.reinterpret([]u8, app.demo.grid.cells))
		write_mapped_buffer(&frame.decoration_buffer, slice.reinterpret([]u8, app.demo.grid.decorations))
		visuals := app.demo.resources.visuals.records[:]
		write_mapped_buffer(&frame.visual_buffer, slice.reinterpret([]u8, visuals))
		if len(app.osd.cells) > 0 {
			write_mapped_buffer(&frame.osd_cell_buffer, slice.reinterpret([]u8, app.osd.cells))
		}
		if len(app.selection.mask) > 0 {
			write_mapped_buffer(&frame.selection_mask_buffer, slice.reinterpret([]u8, app.selection.mask))
		}
		frame.grid_generation = app.grid_generation
		frame.visual_generation = app.demo.resources.visuals.revision
		frame.visuals_uploaded = len(visuals)
		frame.osd_generation = app.osd_generation
		frame.selection_generation = app.selection.mask_generation
	}
	display_grid_clear_dirty(&app.demo.grid)
	app.osd.dirty = false
}

create_synchronization :: proc(app: ^Grimalkin_App) {
	semaphore_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	fence_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}
	for &frame in app.frames {
		vk_must(
			vk.CreateSemaphore(app.device, &semaphore_info, nil, &frame.image_available),
			"creating an image-available semaphore",
		)
		vk_must(
			vk.CreateFence(app.device, &fence_info, nil, &frame.in_flight),
			"creating an in-flight fence",
		)
	}
	create_swapchain_image_synchronization(&app.renderer)
}

create_swapchain_image_synchronization :: proc(renderer: ^Vulkan_Renderer) {
	semaphore_info := vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}
	renderer.render_finished = make([]vk.Semaphore, len(renderer.swapchain_images))
	for &semaphore in renderer.render_finished {
		vk_must(
			vk.CreateSemaphore(renderer.device, &semaphore_info, nil, &semaphore),
			"creating a render-finished semaphore",
		)
	}
	delete(renderer.images_in_flight)
	renderer.images_in_flight = make([]vk.Fence, len(renderer.swapchain_images))
	renderer.active_frame_count = min(len(renderer.frames), len(renderer.swapchain_images))
	renderer.frame_index %= renderer.active_frame_count
}
