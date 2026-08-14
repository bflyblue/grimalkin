package main

import "core:fmt"
import "core:slice"
import "vendor:glfw"
import vk "vendor:vulkan"

query_swapchain_support :: proc(app: ^Vulkan_App) -> Swapchain_Support {
	support := Swapchain_Support{}
	vk_must(
		vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(
			app.physical_device,
			app.surface,
			&support.capabilities,
		),
		"querying surface capabilities",
	)

	format_count: u32
	vk_must(
		vk.GetPhysicalDeviceSurfaceFormatsKHR(
			app.physical_device,
			app.surface,
			&format_count,
			nil,
		),
		"counting surface formats",
	)
	support.formats = make([]vk.SurfaceFormatKHR, format_count, context.temp_allocator)
	vk_must(
		vk.GetPhysicalDeviceSurfaceFormatsKHR(
			app.physical_device,
			app.surface,
			&format_count,
			raw_data(support.formats),
		),
		"querying surface formats",
	)

	present_mode_count: u32
	vk_must(
		vk.GetPhysicalDeviceSurfacePresentModesKHR(
			app.physical_device,
			app.surface,
			&present_mode_count,
			nil,
		),
		"counting presentation modes",
	)
	support.present_modes = make([]vk.PresentModeKHR, present_mode_count, context.temp_allocator)
	vk_must(
		vk.GetPhysicalDeviceSurfacePresentModesKHR(
			app.physical_device,
			app.surface,
			&present_mode_count,
			raw_data(support.present_modes),
		),
		"querying presentation modes",
	)

	return support
}

create_swapchain :: proc(app: ^Vulkan_App) {
	support := query_swapchain_support(app)
	app.surface_format = choose_surface_format(support.formats)
	app.manual_srgb_output = !surface_format_is_srgb(app.surface_format.format)
	app.extent = choose_extent(app, support.capabilities)
	image_usage := vk.ImageUsageFlags{.COLOR_ATTACHMENT}
	if app.framebuffer_readback {
		if .TRANSFER_SRC not_in support.capabilities.supportedUsageFlags {
			fmt.panicf("the Vulkan surface does not support framebuffer readback")
		}
		image_usage |= {.TRANSFER_SRC}
	}

	image_count := support.capabilities.minImageCount + 1
	if support.capabilities.maxImageCount > 0 && image_count > support.capabilities.maxImageCount {
		image_count = support.capabilities.maxImageCount
	}

	queue_family_indices := [2]u32{app.queue_families.graphics, app.queue_families.present}
	create_info := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = app.surface,
		minImageCount    = image_count,
		imageFormat      = app.surface_format.format,
		imageColorSpace  = app.surface_format.colorSpace,
		imageExtent      = app.extent,
		imageArrayLayers = 1,
		imageUsage       = image_usage,
		preTransform     = support.capabilities.currentTransform,
		compositeAlpha   = {.OPAQUE},
		presentMode      = choose_present_mode(support.present_modes),
		clipped          = true,
	}

	if app.queue_families.graphics != app.queue_families.present {
		create_info.imageSharingMode = .CONCURRENT
		create_info.queueFamilyIndexCount = 2
		create_info.pQueueFamilyIndices = &queue_family_indices[0]
	}

	vk_must(
		vk.CreateSwapchainKHR(app.device, &create_info, nil, &app.swapchain),
		"creating the swapchain",
	)

	actual_image_count: u32
	vk_must(
		vk.GetSwapchainImagesKHR(app.device, app.swapchain, &actual_image_count, nil),
		"counting swapchain images",
	)
	app.swapchain_images = make([]vk.Image, actual_image_count)
	vk_must(
		vk.GetSwapchainImagesKHR(
			app.device,
			app.swapchain,
			&actual_image_count,
			raw_data(app.swapchain_images),
		),
		"getting swapchain images",
	)

	app.image_views = make([]vk.ImageView, actual_image_count)
	for image, index in app.swapchain_images {
		view_info := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = image,
			viewType = .D2,
			format = app.surface_format.format,
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		}
		vk_must(
			vk.CreateImageView(app.device, &view_info, nil, &app.image_views[index]),
			"creating a swapchain image view",
		)
	}
}

choose_surface_format :: proc(formats: []vk.SurfaceFormatKHR) -> vk.SurfaceFormatKHR {
	preferred := [4]vk.Format{.B8G8R8A8_SRGB, .R8G8B8A8_SRGB, .B8G8R8A8_UNORM, .R8G8B8A8_UNORM}
	for candidate in preferred {
		for format in formats {
			if format.format == candidate && format.colorSpace == .SRGB_NONLINEAR {
				return format
			}
		}
	}
	fmt.panicf("the Vulkan surface exposes no supported sRGB display format")
}

surface_format_is_srgb :: proc(format: vk.Format) -> bool {
	return format == .B8G8R8A8_SRGB || format == .R8G8B8A8_SRGB
}

choose_extent :: proc(app: ^Vulkan_App, capabilities: vk.SurfaceCapabilitiesKHR) -> vk.Extent2D {
	if capabilities.currentExtent.width != max(u32) {
		return capabilities.currentExtent
	}

	width, height := glfw.GetFramebufferSize(app.window)
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

create_render_pass :: proc(app: ^Vulkan_App) {
	colour_attachment := vk.AttachmentDescription {
		format         = app.surface_format.format,
		samples        = {._1},
		loadOp         = .CLEAR,
		storeOp        = .STORE,
		stencilLoadOp  = .DONT_CARE,
		stencilStoreOp = .DONT_CARE,
		initialLayout  = .UNDEFINED,
		finalLayout    = .PRESENT_SRC_KHR,
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
		vk.CreateRenderPass(app.device, &create_info, nil, &app.render_pass),
		"creating the render pass",
	)
}

create_descriptor_layout :: proc(app: ^Vulkan_App) {
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
			descriptorCount = app.texture_capacity,
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
	create_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		pNext        = &binding_flags_info,
		bindingCount = u32(len(bindings)),
		pBindings    = &bindings[0],
	}
	vk_must(
		vk.CreateDescriptorSetLayout(app.device, &create_info, nil, &app.descriptor_layout),
		"creating the text descriptor layout",
	)
}

create_padding_glow_descriptor_layout :: proc(app: ^Vulkan_App) {
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
	create_info := vk.DescriptorSetLayoutCreateInfo {
		sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = u32(len(bindings)),
		pBindings = &bindings[0],
	}
	vk_must(
		vk.CreateDescriptorSetLayout(
			app.device,
			&create_info,
			nil,
			&app.padding_glow_descriptor_layout,
		),
		"creating the padding glow descriptor layout",
	)
}

Fullscreen_Pipeline_Spec :: struct {
	name:              string,
	fragment_shader:   []byte,
	render_pass:       vk.RenderPass,
	descriptor_layout: vk.DescriptorSetLayout,
	push_constant_size: u32,
	blend:             bool,
	pipeline_layout:   vk.PipelineLayout,
}

create_fullscreen_pipeline :: proc(
	app: ^Vulkan_App,
	spec: Fullscreen_Pipeline_Spec,
) -> (vk.PipelineLayout, vk.Pipeline) {
	vertex_module := create_shader_module(app.device, FULLSCREEN_VERTEX_SHADER)
	defer vk.DestroyShaderModule(app.device, vertex_module, nil)
	fragment_module := create_shader_module(app.device, spec.fragment_shader)
	defer vk.DestroyShaderModule(app.device, fragment_module, nil)
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

	layout := spec.pipeline_layout
	if layout == 0 {
		push_range := vk.PushConstantRange{stageFlags = {.FRAGMENT}, size = spec.push_constant_size}
		layout_info := vk.PipelineLayoutCreateInfo{sType = .PIPELINE_LAYOUT_CREATE_INFO}
		descriptor_layout := spec.descriptor_layout
		if spec.descriptor_layout != 0 {
			layout_info.setLayoutCount = 1
			layout_info.pSetLayouts = &descriptor_layout
		}
		if spec.push_constant_size > 0 {
			layout_info.pushConstantRangeCount = 1
			layout_info.pPushConstantRanges = &push_range
		}
		vk_must(
			vk.CreatePipelineLayout(app.device, &layout_info, nil, &layout),
			fmt.tprintf("creating the %s pipeline layout", spec.name),
		)
	}
	pipeline: vk.Pipeline
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
		layout = layout,
		renderPass = spec.render_pass,
		subpass = 0,
		basePipelineIndex = -1,
	}
	vk_must(
		vk.CreateGraphicsPipelines(app.device, 0, 1, &pipeline_info, nil, &pipeline),
		fmt.tprintf("creating the %s graphics pipeline", spec.name),
	)
	return layout, pipeline
}

create_graphics_pipeline :: proc(app: ^Vulkan_App) {
	app.pipeline_layout, app.pipeline = create_fullscreen_pipeline(
		app,
		{
			name = "text",
			fragment_shader = FRAGMENT_SHADER,
			render_pass = app.render_pass,
			descriptor_layout = app.descriptor_layout,
			push_constant_size = u32(size_of(Text_Layout_Push)),
		},
	)
}

create_padding_glow_source_render_pass :: proc(app: ^Vulkan_App) {
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
		vk.CreateRenderPass(app.device, &create_info, nil, &app.padding_glow_source_render_pass),
		"creating the padding glow source render pass",
	)
}

create_padding_glow_source_pipeline :: proc(app: ^Vulkan_App) {
	create_padding_glow_source_pipeline_with_fragment(
		app,
		FRAGMENT_SHADER,
		&app.padding_glow_source_pipeline,
	)
}

create_padding_glow_background_pipeline :: proc(app: ^Vulkan_App) {
	create_padding_glow_source_pipeline_with_fragment(
		app,
		PADDING_GLOW_BACKGROUND_FRAGMENT_SHADER,
		&app.padding_glow_background_pipeline,
	)
}

create_padding_glow_source_pipeline_with_fragment :: proc(
	app: ^Vulkan_App,
	fragment_shader: []byte,
	pipeline: ^vk.Pipeline,
) {
	_, pipeline^ = create_fullscreen_pipeline(
		app,
		{
			name = "padding glow source",
			fragment_shader = fragment_shader,
			render_pass = app.padding_glow_source_render_pass,
			pipeline_layout = app.pipeline_layout,
		},
	)
}

create_padding_glow_pipeline :: proc(app: ^Vulkan_App) {
	app.padding_glow_pipeline_layout, app.padding_glow_pipeline = create_fullscreen_pipeline(
		app,
		{
			name = "padding glow",
			fragment_shader = PADDING_GLOW_FRAGMENT_SHADER,
			render_pass = app.render_pass,
			descriptor_layout = app.padding_glow_descriptor_layout,
			push_constant_size = u32(size_of(Padding_Glow_Push)),
		},
	)
}

create_osd_pipeline :: proc(app: ^Vulkan_App) {
	app.osd_pipeline_layout, app.osd_pipeline = create_fullscreen_pipeline(
		app,
		{
			name = "OSD",
			fragment_shader = OSD_FRAGMENT_SHADER,
			render_pass = app.render_pass,
			descriptor_layout = app.descriptor_layout,
			push_constant_size = u32(size_of(Osd_Push)),
			blend = true,
		},
	)
}

create_selection_pipeline :: proc(app: ^Vulkan_App) {
	app.selection_pipeline_layout, app.selection_pipeline = create_fullscreen_pipeline(
		app,
		{
			name = "selection",
			fragment_shader = SELECTION_FRAGMENT_SHADER,
			render_pass = app.render_pass,
			descriptor_layout = app.descriptor_layout,
			push_constant_size = u32(size_of(Selection_Push)),
			blend = true,
		},
	)
}

create_scroll_indicator_pipeline :: proc(app: ^Vulkan_App) {
	app.scroll_indicator_pipeline_layout, app.scroll_indicator_pipeline = create_fullscreen_pipeline(
		app,
		{
			name = "scroll indicator",
			fragment_shader = SCROLL_INDICATOR_FRAGMENT_SHADER,
			render_pass = app.render_pass,
			push_constant_size = u32(size_of(Scroll_Indicator_Push)),
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

create_framebuffers :: proc(app: ^Vulkan_App) {
	app.framebuffers = make([]vk.Framebuffer, len(app.image_views))
	for &image_view, index in app.image_views {
		create_info := vk.FramebufferCreateInfo {
			sType           = .FRAMEBUFFER_CREATE_INFO,
			renderPass      = app.render_pass,
			attachmentCount = 1,
			pAttachments    = &image_view,
			width           = app.extent.width,
			height          = app.extent.height,
			layers          = 1,
		}
		vk_must(
			vk.CreateFramebuffer(app.device, &create_info, nil, &app.framebuffers[index]),
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
	app: ^Vulkan_App,
	target: ^Offscreen_Target,
) {
	image_info := vk.ImageCreateInfo {
		sType = .IMAGE_CREATE_INFO,
		imageType = .D2,
		format = PADDING_GLOW_SOURCE_FORMAT,
		extent = {width = app.extent.width, height = app.extent.height, depth = 1},
		mipLevels = 1,
		arrayLayers = 1,
		samples = {._1},
		tiling = .OPTIMAL,
		usage = {.COLOR_ATTACHMENT, .SAMPLED},
		sharingMode = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	vk_must(vk.CreateImage(app.device, &image_info, nil, &target.image), "creating a padding glow source image")
	requirements: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(app.device, target.image, &requirements)
	allocate_info := vk.MemoryAllocateInfo {
		sType = .MEMORY_ALLOCATE_INFO,
		allocationSize = requirements.size,
		memoryTypeIndex = find_memory_type(app, requirements.memoryTypeBits, {.DEVICE_LOCAL}),
	}
	vk_must(vk.AllocateMemory(app.device, &allocate_info, nil, &target.memory), "allocating padding glow source memory")
	vk_must(vk.BindImageMemory(app.device, target.image, target.memory, 0), "binding padding glow source memory")
	attachment_view_info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = target.image,
		viewType = .D2,
		format = PADDING_GLOW_SOURCE_FORMAT,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	vk_must(
		vk.CreateImageView(app.device, &attachment_view_info, nil, &target.attachment_view),
		"creating a padding glow source attachment view",
	)
	sampled_view_info := attachment_view_info
	sampled_view_info.subresourceRange.levelCount = 1
	vk_must(
		vk.CreateImageView(app.device, &sampled_view_info, nil, &target.sampled_view),
		"creating a padding glow source sampled view",
	)
	framebuffer_info := vk.FramebufferCreateInfo {
		sType = .FRAMEBUFFER_CREATE_INFO,
		renderPass = app.padding_glow_source_render_pass,
		attachmentCount = 1,
		pAttachments = &target.attachment_view,
		width = app.extent.width,
		height = app.extent.height,
		layers = 1,
	}
	vk_must(
		vk.CreateFramebuffer(app.device, &framebuffer_info, nil, &target.framebuffer),
		"creating a padding glow source framebuffer",
	)
}

create_padding_glow_source_resources :: proc(app: ^Vulkan_App) {
	format_properties: vk.FormatProperties
	vk.GetPhysicalDeviceFormatProperties(
		app.physical_device,
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
		vk.CreateSampler(app.device, &sampler_info, nil, &app.padding_glow_sampler),
		"creating the padding glow source sampler",
	)

	for &frame in app.frames {
		create_padding_glow_source_target(app, &frame.padding_glow_source)
		create_padding_glow_source_target(app, &frame.padding_glow_background)
	}

	pool_size := vk.DescriptorPoolSize {
		type = .COMBINED_IMAGE_SAMPLER,
		descriptorCount = u32(len(app.frames) * 2),
	}
	pool_info := vk.DescriptorPoolCreateInfo {
		sType = .DESCRIPTOR_POOL_CREATE_INFO,
		maxSets = u32(len(app.frames)),
		poolSizeCount = 1,
		pPoolSizes = &pool_size,
	}
	vk_must(
		vk.CreateDescriptorPool(
			app.device,
			&pool_info,
			nil,
			&app.padding_glow_descriptor_pool,
		),
		"creating the padding glow descriptor pool",
	)
	layouts := make([]vk.DescriptorSetLayout, len(app.frames), context.temp_allocator)
	for &layout in layouts do layout = app.padding_glow_descriptor_layout
	sets := make([]vk.DescriptorSet, len(app.frames), context.temp_allocator)
	set_allocate_info := vk.DescriptorSetAllocateInfo {
		sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool = app.padding_glow_descriptor_pool,
		descriptorSetCount = u32(len(sets)),
		pSetLayouts = raw_data(layouts),
	}
	vk_must(
		vk.AllocateDescriptorSets(app.device, &set_allocate_info, raw_data(sets)),
		"allocating padding glow descriptor sets",
	)
	for &frame, index in app.frames {
		frame.padding_glow_descriptor_set = sets[index]
		image_infos := [2]vk.DescriptorImageInfo {
			{
			sampler = app.padding_glow_sampler,
			imageView = frame.padding_glow_source.sampled_view,
			imageLayout = .SHADER_READ_ONLY_OPTIMAL,
			},
			{
				sampler = app.padding_glow_sampler,
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
		vk.UpdateDescriptorSets(app.device, 2, &writes[0], 0, nil)
	}
}

create_commands :: proc(app: ^Vulkan_App) {
	app.frames = make([]Frame_Context, MAX_FRAMES_IN_FLIGHT)
	app.active_frame_count = min(MAX_FRAMES_IN_FLIGHT, len(app.swapchain_images))
	app.images_in_flight = make([]vk.Fence, len(app.swapchain_images))
	pool_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = app.queue_families.graphics,
	}
	vk_must(
		vk.CreateCommandPool(app.device, &pool_info, nil, &app.command_pool),
		"creating the command pool",
	)

	command_buffers := make([]vk.CommandBuffer, len(app.frames) + 1, context.temp_allocator)
	allocate_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = app.command_pool,
		level              = .PRIMARY,
		commandBufferCount = u32(len(command_buffers)),
	}
	vk_must(
		vk.AllocateCommandBuffers(app.device, &allocate_info, raw_data(command_buffers)),
		"allocating command buffers",
	)
	app.command_buffer = command_buffers[0]
	for &frame, index in app.frames do frame.command_buffer = command_buffers[index + 1]
	fence_info := vk.FenceCreateInfo{sType = .FENCE_CREATE_INFO, flags = {.SIGNALED}}
	vk_must(
		vk.CreateFence(app.device, &fence_info, nil, &app.upload_fence),
		"creating the texture-upload fence",
	)
}

create_timestamp_queries :: proc(app: ^Vulkan_App) {
	family_count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(app.physical_device, &family_count, nil)
	families := make([]vk.QueueFamilyProperties, family_count, context.temp_allocator)
	vk.GetPhysicalDeviceQueueFamilyProperties(
		app.physical_device,
		&family_count,
		raw_data(families),
	)
	app.timestamp_bits = families[app.queue_families.graphics].timestampValidBits
	if app.timestamp_bits == 0 {
		fmt.println("Vulkan timestamp queries are unavailable on the graphics queue")
		return
	}

	properties: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(app.physical_device, &properties)
	app.timestamp_period = f64(properties.limits.timestampPeriod)
	create_info := vk.QueryPoolCreateInfo {
		sType      = .QUERY_POOL_CREATE_INFO,
		queryType  = .TIMESTAMP,
		queryCount = 2,
	}
	for &frame in app.frames {
		vk_must(
			vk.CreateQueryPool(app.device, &create_info, nil, &frame.timestamp_pool),
			"creating a benchmark timestamp query pool",
		)
	}
}
