package main

import "core:fmt"
import "core:slice"
import "vendor:glfw"
import vk "vendor:vulkan"

query_swapchain_support :: proc(renderer: ^Vulkan_Renderer) -> (Swapchain_Support, bool) {
	support := Swapchain_Support{}
	if vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(
			renderer.physical_device,
			renderer.surface,
			&support.capabilities,
		) != .SUCCESS {
		return {}, false
	}

	format_count: u32
	if vk.GetPhysicalDeviceSurfaceFormatsKHR(
			renderer.physical_device,
			renderer.surface,
			&format_count,
			nil,
		) != .SUCCESS || format_count == 0 {
		return {}, false
	}
	support.formats = make([]vk.SurfaceFormatKHR, format_count, context.temp_allocator)
	if vk.GetPhysicalDeviceSurfaceFormatsKHR(
			renderer.physical_device,
			renderer.surface,
			&format_count,
			raw_data(support.formats),
		) != .SUCCESS {
		return {}, false
	}

	present_mode_count: u32
	if vk.GetPhysicalDeviceSurfacePresentModesKHR(
			renderer.physical_device,
			renderer.surface,
			&present_mode_count,
			nil,
		) != .SUCCESS || present_mode_count == 0 {
		return {}, false
	}
	support.present_modes = make([]vk.PresentModeKHR, present_mode_count, context.temp_allocator)
	if vk.GetPhysicalDeviceSurfacePresentModesKHR(
			renderer.physical_device,
			renderer.surface,
			&present_mode_count,
			raw_data(support.present_modes),
		) != .SUCCESS {
		return {}, false
	}

	return support, true
}

create_swapchain :: proc(
	renderer: ^Vulkan_Renderer,
	window: glfw.WindowHandle,
	framebuffer_readback: bool,
) -> bool {
	support, support_ok := query_swapchain_support(renderer)
	if !support_ok do return false
	if format, ok := try_choose_surface_format(support.formats); ok {
		renderer.surface_format = format
	} else {
		return false
	}
	renderer.manual_srgb_output = !surface_format_is_srgb(renderer.surface_format.format)
	renderer.extent = choose_extent(renderer, window, support.capabilities)
	image_usage := vk.ImageUsageFlags{.COLOR_ATTACHMENT}
	if framebuffer_readback {
		if .TRANSFER_SRC not_in support.capabilities.supportedUsageFlags {
			return false
		}
		image_usage |= {.TRANSFER_SRC}
	}

	image_count := support.capabilities.minImageCount + 1
	if support.capabilities.maxImageCount > 0 && image_count > support.capabilities.maxImageCount {
		image_count = support.capabilities.maxImageCount
	}

	queue_family_indices := [2]u32{renderer.queue_families.graphics, renderer.queue_families.present}
	create_info := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = renderer.surface,
		minImageCount    = image_count,
		imageFormat      = renderer.surface_format.format,
		imageColorSpace  = renderer.surface_format.colorSpace,
		imageExtent      = renderer.extent,
		imageArrayLayers = 1,
		imageUsage       = image_usage,
		preTransform     = support.capabilities.currentTransform,
		compositeAlpha   = {.OPAQUE},
		presentMode      = choose_present_mode(support.present_modes),
		clipped          = true,
	}

	if renderer.queue_families.graphics != renderer.queue_families.present {
		create_info.imageSharingMode = .CONCURRENT
		create_info.queueFamilyIndexCount = 2
		create_info.pQueueFamilyIndices = &queue_family_indices[0]
	}

	if vk.CreateSwapchainKHR(renderer.device, &create_info, nil, &renderer.swapchain) != .SUCCESS {
		renderer.swapchain = 0
		return false
	}

	actual_image_count: u32
	if vk.GetSwapchainImagesKHR(renderer.device, renderer.swapchain, &actual_image_count, nil) != .SUCCESS ||
	   actual_image_count == 0 {
		return false
	}
	renderer.swapchain_images = make([]vk.Image, actual_image_count)
	if vk.GetSwapchainImagesKHR(
			renderer.device,
			renderer.swapchain,
			&actual_image_count,
			raw_data(renderer.swapchain_images),
		) != .SUCCESS {
		return false
	}

	renderer.image_views = make([]vk.ImageView, actual_image_count)
	for image, index in renderer.swapchain_images {
		view_info := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = image,
			viewType = .D2,
			format = renderer.surface_format.format,
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		}
		if vk.CreateImageView(renderer.device, &view_info, nil, &renderer.image_views[index]) != .SUCCESS {
			return false
		}
	}
	return true
}

try_choose_surface_format :: proc(formats: []vk.SurfaceFormatKHR) -> (vk.SurfaceFormatKHR, bool) {
	preferred := [4]vk.Format{.B8G8R8A8_SRGB, .R8G8B8A8_SRGB, .B8G8R8A8_UNORM, .R8G8B8A8_UNORM}
	for candidate in preferred {
		for format in formats {
			if format.format == candidate && format.colorSpace == .SRGB_NONLINEAR {
				return format, true
			}
		}
	}
	return {}, false
}

choose_surface_format :: proc(formats: []vk.SurfaceFormatKHR) -> vk.SurfaceFormatKHR {
	if format, ok := try_choose_surface_format(formats); ok do return format
	fmt.panicf("the Vulkan surface exposes no supported sRGB display format")
}

surface_format_is_srgb :: proc(format: vk.Format) -> bool {
	return format == .B8G8R8A8_SRGB || format == .R8G8B8A8_SRGB
}

choose_extent :: proc(
	renderer: ^Vulkan_Renderer,
	window: glfw.WindowHandle,
	capabilities: vk.SurfaceCapabilitiesKHR,
) -> vk.Extent2D {
	if capabilities.currentExtent.width != max(u32) {
		return capabilities.currentExtent
	}

	width, height := glfw.GetFramebufferSize(window)
	return vk.Extent2D {
		width = clamp(
			u32(width),
			capabilities.minImageExtent.width,
			capabilities.maxImageExtent.width,
		),
		height = clamp(
			u32(height),
			capabilities.minImageExtent.height,
			capabilities.maxImageExtent.height,
		),
	}
}

create_render_pass :: proc(renderer: ^Vulkan_Renderer) {
	// A headless target is never presented, and PRESENT_SRC_KHR is only valid
	// for swapchain images, so it stays in the attachment layout instead.
	final_layout: vk.ImageLayout =
		renderer.headless_image != 0 ? .COLOR_ATTACHMENT_OPTIMAL : .PRESENT_SRC_KHR
	colour_attachment := vk.AttachmentDescription {
		format         = renderer.surface_format.format,
		samples        = {._1},
		loadOp         = .CLEAR,
		storeOp        = .STORE,
		stencilLoadOp  = .DONT_CARE,
		stencilStoreOp = .DONT_CARE,
		initialLayout  = .UNDEFINED,
		finalLayout    = final_layout,
	}
	colour_reference := vk.AttachmentReference {
		attachment = 0,
		layout     = .COLOR_ATTACHMENT_OPTIMAL,
	}
	subpass := vk.SubpassDescription {
		pipelineBindPoint    = .GRAPHICS,
		colorAttachmentCount = 1,
		pColorAttachments    = &colour_reference,
	}
	dependency := vk.SubpassDependency {
		srcSubpass    = vk.SUBPASS_EXTERNAL,
		dstSubpass    = 0,
		srcStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
		dstStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
		dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
	}
	create_info := vk.RenderPassCreateInfo {
		sType           = .RENDER_PASS_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &colour_attachment,
		subpassCount    = 1,
		pSubpasses      = &subpass,
		dependencyCount = 1,
		pDependencies   = &dependency,
	}
	vk_must(
		vk.CreateRenderPass(renderer.device, &create_info, nil, &renderer.render_pass),
		"creating the render pass",
	)
}

// Set 1 for the text pipeline: the Kitty placements composited between the
// cell background and the glyph. Its own set because set 0 ends with a variable
// descriptor count binding, which Vulkan requires to be last.
create_descriptor_layout_from_bindings :: proc(
	renderer: ^Vulkan_Renderer,
	bindings: []vk.DescriptorSetLayoutBinding,
	output: ^vk.DescriptorSetLayout,
	name: string,
	next: rawptr = nil,
) {
	create_info := vk.DescriptorSetLayoutCreateInfo {
		sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		pNext = next,
		bindingCount = u32(len(bindings)),
		pBindings = raw_data(bindings),
	}
	vk_must(
		vk.CreateDescriptorSetLayout(renderer.device, &create_info, nil, output),
		fmt.tprintf("creating the %s descriptor layout", name),
	)
}

create_image_placement_descriptor_layout :: proc(renderer: ^Vulkan_Renderer) {
	bindings := [1]vk.DescriptorSetLayoutBinding {{
		binding = 0,
		descriptorType = .STORAGE_BUFFER,
		descriptorCount = 1,
		stageFlags = {.FRAGMENT},
	}}
	create_descriptor_layout_from_bindings(
		renderer,
		bindings[:],
		&renderer.image_placement_descriptor_layout,
		"image placement",
	)
}

create_descriptor_layout :: proc(renderer: ^Vulkan_Renderer) {
	bindings := [4]vk.DescriptorSetLayoutBinding {
		{
			binding = 0,
			descriptorType = .STORAGE_BUFFER,
			descriptorCount = 1,
			stageFlags = {.FRAGMENT},
		},
		{
			binding = 1,
			descriptorType = .STORAGE_BUFFER,
			descriptorCount = 1,
			stageFlags = {.FRAGMENT},
		},
		{
			binding = 2,
			descriptorType = .STORAGE_BUFFER,
			descriptorCount = 1,
			stageFlags = {.FRAGMENT},
		},
		{
			binding = 3,
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = renderer.texture_capacity,
			stageFlags = {.FRAGMENT},
		},
	}
	binding_flags := [4]vk.DescriptorBindingFlags {
		{},
		{},
		{},
		{.PARTIALLY_BOUND, .VARIABLE_DESCRIPTOR_COUNT},
	}
	binding_flags_info := vk.DescriptorSetLayoutBindingFlagsCreateInfo {
		sType         = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
		bindingCount  = u32(len(binding_flags)),
		pBindingFlags = &binding_flags[0],
	}
	create_descriptor_layout_from_bindings(
		renderer,
		bindings[:],
		&renderer.descriptor_layout,
		"text",
		rawptr(&binding_flags_info),
	)
}

create_padding_glow_descriptor_layout :: proc(renderer: ^Vulkan_Renderer) {
	bindings := [2]vk.DescriptorSetLayoutBinding {
		{
			binding = 0,
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = 1,
			stageFlags = {.FRAGMENT},
		},
		{
			binding = 1,
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = 1,
			stageFlags = {.FRAGMENT},
		},
	}
	create_descriptor_layout_from_bindings(
		renderer,
		bindings[:],
		&renderer.padding_glow_descriptor_layout,
		"padding glow",
	)
}

Fullscreen_Pipeline :: struct {
	layout:      vk.PipelineLayout,
	handle:      vk.Pipeline,
	owns_layout: bool,
}

Fullscreen_Pipeline_Spec :: struct {
	name:              string,
	fragment_shader:   []byte,
	render_pass:       vk.RenderPass,
	descriptor_layout: vk.DescriptorSetLayout,
	// Bound as set 1 when present. The text pipeline uses it for the Kitty
	// below-text placements, which cannot join set 0: its bindless texture
	// array has a variable descriptor count and so must stay the last binding.
	second_descriptor_layout: vk.DescriptorSetLayout,
	push_constant_size: u32,
	blend:             bool,
	pipeline_layout:   vk.PipelineLayout,
}

create_fullscreen_pipeline :: proc(
	renderer: ^Vulkan_Renderer,
	spec: Fullscreen_Pipeline_Spec,
) -> Fullscreen_Pipeline {
	vertex_module := create_shader_module(renderer.device, FULLSCREEN_VERTEX_SHADER)
	defer vk.DestroyShaderModule(renderer.device, vertex_module, nil)
	fragment_module := create_shader_module(renderer.device, spec.fragment_shader)
	defer vk.DestroyShaderModule(renderer.device, fragment_module, nil)
	stages := [2]vk.PipelineShaderStageCreateInfo {
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX}, module = vertex_module, pName = "main"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = fragment_module, pName = "main"},
	}
	vertex_input := vk.PipelineVertexInputStateCreateInfo{sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO}
	assembly := vk.PipelineInputAssemblyStateCreateInfo {
		sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_STRIP,
	}
	viewport := vk.PipelineViewportStateCreateInfo {
		sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount = 1,
	}
	raster := vk.PipelineRasterizationStateCreateInfo {
		sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = .FILL,
		lineWidth = 1,
		frontFace = .CLOCKWISE,
	}
	multisample := vk.PipelineMultisampleStateCreateInfo {
		sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
	}
	blend_attachment := vk.PipelineColorBlendAttachmentState {
		blendEnable = b32(spec.blend),
		srcColorBlendFactor = .ONE,
		dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
		colorBlendOp = .ADD,
		srcAlphaBlendFactor = .ONE,
		dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
		alphaBlendOp = .ADD,
		colorWriteMask = {.R, .G, .B, .A},
	}
	blend := vk.PipelineColorBlendStateCreateInfo {
		sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments = &blend_attachment,
	}
	dynamic_states := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_info := vk.PipelineDynamicStateCreateInfo {
		sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(dynamic_states)),
		pDynamicStates = &dynamic_states[0],
	}

	result := Fullscreen_Pipeline {
		layout = spec.pipeline_layout,
		owns_layout = spec.pipeline_layout == 0,
	}
	if result.layout == 0 {
		push_range := vk.PushConstantRange{stageFlags = {.FRAGMENT}, size = spec.push_constant_size}
		layout_info := vk.PipelineLayoutCreateInfo{sType = .PIPELINE_LAYOUT_CREATE_INFO}
		set_layouts := [2]vk.DescriptorSetLayout{spec.descriptor_layout, spec.second_descriptor_layout}
		if spec.descriptor_layout != 0 {
			layout_info.setLayoutCount = spec.second_descriptor_layout != 0 ? 2 : 1
			layout_info.pSetLayouts = &set_layouts[0]
		}
		if spec.push_constant_size > 0 {
			layout_info.pushConstantRangeCount = 1
			layout_info.pPushConstantRanges = &push_range
		}
		vk_must(
			vk.CreatePipelineLayout(renderer.device, &layout_info, nil, &result.layout),
			fmt.tprintf("creating the %s pipeline layout", spec.name),
		)
	}
	pipeline_info := vk.GraphicsPipelineCreateInfo {
		sType = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount = u32(len(stages)),
		pStages = &stages[0],
		pVertexInputState = &vertex_input,
		pInputAssemblyState = &assembly,
		pViewportState = &viewport,
		pRasterizationState = &raster,
		pMultisampleState = &multisample,
		pColorBlendState = &blend,
		pDynamicState = &dynamic_info,
		layout = result.layout,
		renderPass = spec.render_pass,
		subpass = 0,
		basePipelineIndex = -1,
	}
	vk_must(
		vk.CreateGraphicsPipelines(renderer.device, 0, 1, &pipeline_info, nil, &result.handle),
		fmt.tprintf("creating the %s graphics pipeline", spec.name),
	)
	return result
}

destroy_fullscreen_pipeline :: proc(device: vk.Device, pipeline: ^Fullscreen_Pipeline) {
	if pipeline == nil do return
	if pipeline.handle != 0 do vk.DestroyPipeline(device, pipeline.handle, nil)
	if pipeline.owns_layout && pipeline.layout != 0 {
		vk.DestroyPipelineLayout(device, pipeline.layout, nil)
	}
	pipeline^ = {}
}

create_padding_glow_source_render_pass :: proc(renderer: ^Vulkan_Renderer) {
	colour_attachment := vk.AttachmentDescription {
		format = PADDING_GLOW_SOURCE_FORMAT,
		samples = {._1},
		loadOp = .CLEAR,
		storeOp = .STORE,
		stencilLoadOp = .DONT_CARE,
		stencilStoreOp = .DONT_CARE,
		initialLayout = .UNDEFINED,
		finalLayout = .SHADER_READ_ONLY_OPTIMAL,
	}
	colour_reference := vk.AttachmentReference{attachment = 0, layout = .COLOR_ATTACHMENT_OPTIMAL}
	subpass := vk.SubpassDescription {
		pipelineBindPoint = .GRAPHICS,
		colorAttachmentCount = 1,
		pColorAttachments = &colour_reference,
	}
	dependencies := [2]vk.SubpassDependency {
		{
			srcSubpass = vk.SUBPASS_EXTERNAL,
			dstSubpass = 0,
			srcStageMask = {.TOP_OF_PIPE},
			dstStageMask = {.COLOR_ATTACHMENT_OUTPUT},
			dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
		},
		{
			srcSubpass = 0,
			dstSubpass = vk.SUBPASS_EXTERNAL,
			srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
			dstStageMask = {.FRAGMENT_SHADER},
			srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
			dstAccessMask = {.SHADER_READ},
		},
	}
	create_info := vk.RenderPassCreateInfo {
		sType = .RENDER_PASS_CREATE_INFO,
		attachmentCount = 1,
		pAttachments = &colour_attachment,
		subpassCount = 1,
		pSubpasses = &subpass,
		dependencyCount = u32(len(dependencies)),
		pDependencies = &dependencies[0],
	}
	vk_must(
		vk.CreateRenderPass(renderer.device, &create_info, nil, &renderer.padding_glow_source_render_pass),
		"creating the padding glow source render pass",
	)
}

create_fullscreen_pipelines :: proc(renderer: ^Vulkan_Renderer) {
	renderer.text_pipeline = create_fullscreen_pipeline(
		renderer,
		{
			name = "text",
			fragment_shader = FRAGMENT_SHADER,
			render_pass = renderer.render_pass,
			descriptor_layout = renderer.descriptor_layout,
			second_descriptor_layout = renderer.image_placement_descriptor_layout,
			push_constant_size = u32(size_of(Text_Layout_Push)),
		},
	)
	renderer.padding_glow_source_pipeline = create_fullscreen_pipeline(
		renderer,
		{
			name = "padding glow source",
			fragment_shader = FRAGMENT_SHADER,
			render_pass = renderer.padding_glow_source_render_pass,
			pipeline_layout = renderer.text_pipeline.layout,
		},
	)
	renderer.padding_glow_background_pipeline = create_fullscreen_pipeline(
		renderer,
		{
			name = "padding glow background",
			fragment_shader = PADDING_GLOW_BACKGROUND_FRAGMENT_SHADER,
			render_pass = renderer.padding_glow_source_render_pass,
			pipeline_layout = renderer.text_pipeline.layout,
		},
	)
	renderer.padding_glow_pipeline = create_fullscreen_pipeline(
		renderer,
		{
			name = "padding glow",
			fragment_shader = PADDING_GLOW_FRAGMENT_SHADER,
			render_pass = renderer.render_pass,
			descriptor_layout = renderer.padding_glow_descriptor_layout,
			push_constant_size = u32(size_of(Padding_Glow_Push)),
		},
	)
	renderer.osd_pipeline = create_fullscreen_pipeline(
		renderer,
		{
			name = "OSD",
			fragment_shader = OSD_FRAGMENT_SHADER,
			render_pass = renderer.render_pass,
			descriptor_layout = renderer.descriptor_layout,
			push_constant_size = u32(size_of(Osd_Push)),
			blend = true,
		},
	)
	renderer.selection_pipeline = create_fullscreen_pipeline(
		renderer,
		{
			name = "selection",
			fragment_shader = SELECTION_FRAGMENT_SHADER,
			render_pass = renderer.render_pass,
			descriptor_layout = renderer.descriptor_layout,
			push_constant_size = u32(size_of(Selection_Push)),
			blend = true,
		},
	)
	renderer.scroll_indicator_pipeline = create_fullscreen_pipeline(
		renderer,
		{
			name = "scroll indicator",
			fragment_shader = SCROLL_INDICATOR_FRAGMENT_SHADER,
			render_pass = renderer.render_pass,
			push_constant_size = u32(size_of(Scroll_Indicator_Push)),
			blend = true,
		},
	)
	renderer.image_quad_pipeline = create_fullscreen_pipeline(
		renderer,
		{
			name = "image quad",
			fragment_shader = IMAGE_QUAD_FRAGMENT_SHADER,
			render_pass = renderer.render_pass,
			descriptor_layout = renderer.descriptor_layout,
			push_constant_size = u32(size_of(Image_Quad_Push)),
			// Images arrive premultiplied, matching the shared blend factors.
			blend = true,
		},
	)
}

create_shader_module :: proc(device: vk.Device, code: []byte) -> vk.ShaderModule {
	words := slice.reinterpret([]u32, code)
	create_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(code),
		pCode    = raw_data(words),
	}
	module: vk.ShaderModule
	vk_must(vk.CreateShaderModule(device, &create_info, nil, &module), "creating a shader module")
	return module
}

create_framebuffers :: proc(renderer: ^Vulkan_Renderer) {
	renderer.framebuffers = make([]vk.Framebuffer, len(renderer.image_views))
	for &image_view, index in renderer.image_views {
		create_info := vk.FramebufferCreateInfo {
			sType           = .FRAMEBUFFER_CREATE_INFO,
			renderPass      = renderer.render_pass,
			attachmentCount = 1,
			pAttachments    = &image_view,
			width           = renderer.extent.width,
			height          = renderer.extent.height,
			layers          = 1,
		}
		vk_must(
			vk.CreateFramebuffer(renderer.device, &create_info, nil, &renderer.framebuffers[index]),
			"creating a framebuffer",
		)
	}
}

destroy_offscreen_target :: proc(device: vk.Device, target: ^Offscreen_Target) {
	if target.framebuffer != 0 do vk.DestroyFramebuffer(device, target.framebuffer, nil)
	if target.attachment_view != 0 do vk.DestroyImageView(device, target.attachment_view, nil)
	if target.sampled_view != 0 do vk.DestroyImageView(device, target.sampled_view, nil)
	if target.image != 0 do vk.DestroyImage(device, target.image, nil)
	if target.memory != 0 do vk.FreeMemory(device, target.memory, nil)
	target^ = {}
}

create_padding_glow_source_target :: proc(
	renderer: ^Vulkan_Renderer,
	target: ^Offscreen_Target,
) {
	image_info := vk.ImageCreateInfo {
		sType = .IMAGE_CREATE_INFO,
		imageType = .D2,
		format = PADDING_GLOW_SOURCE_FORMAT,
		extent = {width = renderer.extent.width, height = renderer.extent.height, depth = 1},
		mipLevels = 1,
		arrayLayers = 1,
		samples = {._1},
		tiling = .OPTIMAL,
		usage = {.COLOR_ATTACHMENT, .SAMPLED},
		sharingMode = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	vk_must(vk.CreateImage(renderer.device, &image_info, nil, &target.image), "creating a padding glow source image")
	requirements: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(renderer.device, target.image, &requirements)
	allocate_info := vk.MemoryAllocateInfo {
		sType = .MEMORY_ALLOCATE_INFO,
		allocationSize = requirements.size,
		memoryTypeIndex = find_memory_type(renderer, requirements.memoryTypeBits, {.DEVICE_LOCAL}),
	}
	vk_must(vk.AllocateMemory(renderer.device, &allocate_info, nil, &target.memory), "allocating padding glow source memory")
	vk_must(vk.BindImageMemory(renderer.device, target.image, target.memory, 0), "binding padding glow source memory")
	attachment_view_info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = target.image,
		viewType = .D2,
		format = PADDING_GLOW_SOURCE_FORMAT,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	vk_must(
		vk.CreateImageView(renderer.device, &attachment_view_info, nil, &target.attachment_view),
		"creating a padding glow source attachment view",
	)
	sampled_view_info := attachment_view_info
	sampled_view_info.subresourceRange.levelCount = 1
	vk_must(
		vk.CreateImageView(renderer.device, &sampled_view_info, nil, &target.sampled_view),
		"creating a padding glow source sampled view",
	)
	framebuffer_info := vk.FramebufferCreateInfo {
		sType = .FRAMEBUFFER_CREATE_INFO,
		renderPass = renderer.padding_glow_source_render_pass,
		attachmentCount = 1,
		pAttachments = &target.attachment_view,
		width = renderer.extent.width,
		height = renderer.extent.height,
		layers = 1,
	}
	vk_must(
		vk.CreateFramebuffer(renderer.device, &framebuffer_info, nil, &target.framebuffer),
		"creating a padding glow source framebuffer",
	)
}

create_padding_glow_source_resources :: proc(renderer: ^Vulkan_Renderer) {
	format_properties: vk.FormatProperties
	vk.GetPhysicalDeviceFormatProperties(
		renderer.physical_device,
		PADDING_GLOW_SOURCE_FORMAT,
		&format_properties,
	)
	required_features := vk.FormatFeatureFlags {
		.COLOR_ATTACHMENT,
		.SAMPLED_IMAGE,
		.SAMPLED_IMAGE_FILTER_LINEAR,
	}
	if (format_properties.optimalTilingFeatures & required_features) != required_features {
		fmt.panicf(
			"Vulkan device cannot use %v as a sampled padding-glow render target",
			PADDING_GLOW_SOURCE_FORMAT,
		)
	}

	sampler_info := vk.SamplerCreateInfo {
		sType = .SAMPLER_CREATE_INFO,
		magFilter = .LINEAR,
		minFilter = .LINEAR,
		mipmapMode = .NEAREST,
		addressModeU = .CLAMP_TO_EDGE,
		addressModeV = .CLAMP_TO_EDGE,
		addressModeW = .CLAMP_TO_EDGE,
		maxLod = 0,
	}
	vk_must(
		vk.CreateSampler(renderer.device, &sampler_info, nil, &renderer.padding_glow_sampler),
		"creating the padding glow source sampler",
	)

	for &frame in renderer.frames {
		create_padding_glow_source_target(renderer, &frame.padding_glow_source)
		create_padding_glow_source_target(renderer, &frame.padding_glow_background)
	}

	pool_size := vk.DescriptorPoolSize {
		type = .COMBINED_IMAGE_SAMPLER,
		descriptorCount = u32(len(renderer.frames) * 2),
	}
	pool_info := vk.DescriptorPoolCreateInfo {
		sType = .DESCRIPTOR_POOL_CREATE_INFO,
		maxSets = u32(len(renderer.frames)),
		poolSizeCount = 1,
		pPoolSizes = &pool_size,
	}
	vk_must(
		vk.CreateDescriptorPool(
			renderer.device,
			&pool_info,
			nil,
			&renderer.padding_glow_descriptor_pool,
		),
		"creating the padding glow descriptor pool",
	)
	layouts := make([]vk.DescriptorSetLayout, len(renderer.frames), context.temp_allocator)
	for &layout in layouts do layout = renderer.padding_glow_descriptor_layout
	sets := make([]vk.DescriptorSet, len(renderer.frames), context.temp_allocator)
	set_allocate_info := vk.DescriptorSetAllocateInfo {
		sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool = renderer.padding_glow_descriptor_pool,
		descriptorSetCount = u32(len(sets)),
		pSetLayouts = raw_data(layouts),
	}
	vk_must(
		vk.AllocateDescriptorSets(renderer.device, &set_allocate_info, raw_data(sets)),
		"allocating padding glow descriptor sets",
	)
	for &frame, index in renderer.frames {
		frame.padding_glow_descriptor_set = sets[index]
		image_infos := [2]vk.DescriptorImageInfo {
			{
			sampler = renderer.padding_glow_sampler,
			imageView = frame.padding_glow_source.sampled_view,
			imageLayout = .SHADER_READ_ONLY_OPTIMAL,
			},
			{
				sampler = renderer.padding_glow_sampler,
				imageView = frame.padding_glow_background.sampled_view,
				imageLayout = .SHADER_READ_ONLY_OPTIMAL,
			},
		}
		writes: [2]vk.WriteDescriptorSet
		writes[0] = {
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = frame.padding_glow_descriptor_set,
			dstBinding = 0,
			descriptorCount = 1,
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			pImageInfo = &image_infos[0],
		}
		writes[1] = {
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = frame.padding_glow_descriptor_set,
			dstBinding = 1,
			descriptorCount = 1,
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			pImageInfo = &image_infos[1],
		}
		vk.UpdateDescriptorSets(renderer.device, 2, &writes[0], 0, nil)
	}
}

create_commands :: proc(renderer: ^Vulkan_Renderer) {
	renderer.frames = make([]Frame_Context, MAX_FRAMES_IN_FLIGHT)
	renderer.active_frame_count = min(MAX_FRAMES_IN_FLIGHT, len(renderer.swapchain_images))
	renderer.images_in_flight = make([]vk.Fence, len(renderer.swapchain_images))
	pool_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = renderer.queue_families.graphics,
	}
	vk_must(
		vk.CreateCommandPool(renderer.device, &pool_info, nil, &renderer.command_pool),
		"creating the command pool",
	)

	command_buffers := make([]vk.CommandBuffer, len(renderer.frames) + 1, context.temp_allocator)
	allocate_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = renderer.command_pool,
		level              = .PRIMARY,
		commandBufferCount = u32(len(command_buffers)),
	}
	vk_must(
		vk.AllocateCommandBuffers(renderer.device, &allocate_info, raw_data(command_buffers)),
		"allocating command buffers",
	)
	renderer.command_buffer = command_buffers[0]
	for &frame, index in renderer.frames do frame.command_buffer = command_buffers[index + 1]
	fence_info := vk.FenceCreateInfo{sType = .FENCE_CREATE_INFO, flags = {.SIGNALED}}
	vk_must(
		vk.CreateFence(renderer.device, &fence_info, nil, &renderer.upload_fence),
		"creating the texture-upload fence",
	)
}

create_timestamp_queries :: proc(renderer: ^Vulkan_Renderer) {
	family_count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(renderer.physical_device, &family_count, nil)
	families := make([]vk.QueueFamilyProperties, family_count, context.temp_allocator)
	vk.GetPhysicalDeviceQueueFamilyProperties(
		renderer.physical_device,
		&family_count,
		raw_data(families),
	)
	renderer.timestamp_bits = families[renderer.queue_families.graphics].timestampValidBits
	if renderer.timestamp_bits == 0 {
		fmt.println("Vulkan timestamp queries are unavailable on the graphics queue")
		return
	}

	properties: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(renderer.physical_device, &properties)
	renderer.timestamp_period = f64(properties.limits.timestampPeriod)
	create_info := vk.QueryPoolCreateInfo {
		sType      = .QUERY_POOL_CREATE_INFO,
		queryType  = .TIMESTAMP,
		queryCount = 2,
	}
	for &frame in renderer.frames {
		vk_must(
			vk.CreateQueryPool(renderer.device, &create_info, nil, &frame.timestamp_pool),
			"creating a benchmark timestamp query pool",
		)
	}
}
