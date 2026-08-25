package main

import "core:fmt"
import "core:strings"
import "vendor:glfw"
import vk "vendor:vulkan"

init_vulkan :: proc(app: ^Grimalkin_App) {
	vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))
	if vk.CreateInstance == nil {
		fmt.panicf("Vulkan global procedure loading failed")
	}

	create_instance(app)
	vk.load_proc_addresses_instance(app.instance)
	create_debug_messenger(app)

	if !app.headless {
		vk_must(
			glfw.CreateWindowSurface(app.instance, app.window, nil, &app.surface),
			"creating the GLFW window surface",
		)
	}

	pick_physical_device(app)
	create_logical_device(app)
	vk.load_proc_addresses_device(app.device)

	if app.headless {
		create_headless_target(&app.renderer)
	} else {
		create_swapchain(&app.renderer, app.window, app.framebuffer_readback)
	}
	resize_terminal_to_extent(app, app.extent)
	osd_prepare(app)
	create_descriptor_layout(app)
	create_image_placement_descriptor_layout(app)
	create_padding_glow_descriptor_layout(app)
	create_swapchain_resources(&app.renderer)
	create_commands(app)
	create_swapchain_frame_resources(&app.renderer, app.framebuffer_readback)
	when BENCHMARK_MODE {
		create_timestamp_queries(app)
	}
	create_text_resources(app)
	create_synchronization(app)
}

create_swapchain_resources :: proc(renderer: ^Vulkan_Renderer) {
	create_render_pass(renderer)
	create_graphics_pipeline(renderer)
	create_padding_glow_source_render_pass(renderer)
	create_padding_glow_source_pipeline(renderer)
	create_padding_glow_background_pipeline(renderer)
	create_padding_glow_pipeline(renderer)
	create_osd_pipeline(renderer)
	create_selection_pipeline(renderer)
	create_scroll_indicator_pipeline(renderer)
	create_image_quad_pipeline(renderer)
	create_framebuffers(renderer)
}

create_swapchain_frame_resources :: proc(renderer: ^Vulkan_Renderer, framebuffer_readback: bool) {
	create_padding_glow_source_resources(renderer)
	if framebuffer_readback do create_capture_buffer(renderer)
}

text_grid_extent :: proc(app: ^Grimalkin_App) -> vk.Extent2D {
	return {
		width = u32(app.demo.grid.cols) * app.demo.resources.cell_metrics.cell_width,
		height = u32(app.demo.grid.rows) * app.demo.resources.cell_metrics.cell_height,
	}
}

centered_render_area :: proc(frame_extent, content_extent: vk.Extent2D) -> vk.Rect2D {
	extent := vk.Extent2D {
		width  = min(content_extent.width, frame_extent.width),
		height = min(content_extent.height, frame_extent.height),
	}
	return {
		offset = {
			x = i32((frame_extent.width - extent.width) / 2),
			y = i32((frame_extent.height - extent.height) / 2),
		},
		extent = extent,
	}
}

text_render_area :: proc(app: ^Grimalkin_App) -> vk.Rect2D {
	return centered_render_area(app.extent, text_grid_extent(app))
}

grid_dimensions_for_framebuffer :: proc(
	width, height, cell_width, cell_height, padding_x, padding_y: u32,
) -> (
	u16,
	u16,
	bool,
) {
	if width == 0 || height == 0 || cell_width == 0 || cell_height == 0 {
		return 0, 0, false
	}
	usable_width := width > padding_x * 2 ? width - padding_x * 2 : width
	usable_height := height > padding_y * 2 ? height - padding_y * 2 : height
	cols := u16(clamp(max(u32(1), usable_width / cell_width), 1, u32(max(u16))))
	rows := u16(clamp(max(u32(1), usable_height / cell_height), 1, u32(max(u16))))
	return cols, rows, true
}

resize_terminal_to_extent :: proc(app: ^Grimalkin_App, frame_extent: vk.Extent2D, force := false) {
	metrics := app.demo.resources.cell_metrics
	cols, rows, valid := grid_dimensions_for_framebuffer(
		frame_extent.width,
		frame_extent.height,
		metrics.cell_width,
		metrics.cell_height,
		u32(f32(app.settings.padding) * app.content_scale_x + 0.5),
		u32(f32(app.settings.padding) * app.content_scale_y + 0.5),
	)
	if !valid do return
	plan := terminal_resize_plan(
		app.demo.grid.cols,
		app.demo.grid.rows,
		app.terminal_cell_width,
		app.terminal_cell_height,
		cols,
		rows,
		metrics.cell_width,
		metrics.cell_height,
	)
	if !force && !plan.resize do return
	app.terminal_cell_width = metrics.cell_width
	app.terminal_cell_height = metrics.cell_height
	if force || plan.clear_selection do selection_clear(&app.selection)
	terminal_core_resize(&app.demo.terminal, cols, rows, metrics.cell_width, metrics.cell_height)
	if app.demo.session.handle != nil {
		_ = terminal_session_resize(
			&app.demo.session,
			cols,
			rows,
			metrics.cell_width,
			metrics.cell_height,
		)
	}
	_ = refresh_terminal_display(app)
}

refresh_terminal_display :: proc(app: ^Grimalkin_App) -> Display_Compile_Stats {
	// display_compile owns every write to the grid, so the hover underline is
	// lifted before it runs and reapplied afterwards against the new snapshot.
	url_hover_before_compile(app)
	stats := grimalkin_demo_refresh(app.demo) if app.demo.demo_mode else grimalkin_view_refresh(app.demo)
	url_hover_after_compile(app)
	if stats.glyph_cache_full {
		app.glyph_cache_reset_pending = true
		app.redraw = true
	}
	return stats
}

destroy_swapchain_resources :: proc(renderer: ^Vulkan_Renderer) {
	destroy_buffer(renderer.device, &renderer.capture_buffer)
	if renderer.padding_glow_descriptor_pool != 0 {
		vk.DestroyDescriptorPool(renderer.device, renderer.padding_glow_descriptor_pool, nil)
		renderer.padding_glow_descriptor_pool = 0
	}
	if renderer.padding_glow_sampler != 0 {
		vk.DestroySampler(renderer.device, renderer.padding_glow_sampler, nil)
		renderer.padding_glow_sampler = 0
	}
	for &frame in renderer.frames {
		frame.padding_glow_descriptor_set = 0
		destroy_offscreen_target(renderer.device, &frame.padding_glow_source)
		destroy_offscreen_target(renderer.device, &frame.padding_glow_background)
	}
	for framebuffer in renderer.framebuffers do vk.DestroyFramebuffer(renderer.device, framebuffer, nil)
	delete(renderer.framebuffers)
	if renderer.pipeline != 0 do vk.DestroyPipeline(renderer.device, renderer.pipeline, nil)
	if renderer.pipeline_layout != 0 do vk.DestroyPipelineLayout(renderer.device, renderer.pipeline_layout, nil)
	if renderer.padding_glow_pipeline != 0 do vk.DestroyPipeline(renderer.device, renderer.padding_glow_pipeline, nil)
	if renderer.padding_glow_pipeline_layout != 0 do vk.DestroyPipelineLayout(renderer.device, renderer.padding_glow_pipeline_layout, nil)
	if renderer.padding_glow_source_pipeline != 0 do vk.DestroyPipeline(renderer.device, renderer.padding_glow_source_pipeline, nil)
	if renderer.padding_glow_background_pipeline != 0 do vk.DestroyPipeline(renderer.device, renderer.padding_glow_background_pipeline, nil)
	if renderer.padding_glow_source_render_pass != 0 do vk.DestroyRenderPass(renderer.device, renderer.padding_glow_source_render_pass, nil)
	if renderer.osd_pipeline != 0 do vk.DestroyPipeline(renderer.device, renderer.osd_pipeline, nil)
	if renderer.osd_pipeline_layout != 0 do vk.DestroyPipelineLayout(renderer.device, renderer.osd_pipeline_layout, nil)
	if renderer.selection_pipeline != 0 do vk.DestroyPipeline(renderer.device, renderer.selection_pipeline, nil)
	if renderer.selection_pipeline_layout != 0 do vk.DestroyPipelineLayout(renderer.device, renderer.selection_pipeline_layout, nil)
	if renderer.image_quad_pipeline != 0 do vk.DestroyPipeline(renderer.device, renderer.image_quad_pipeline, nil)
	if renderer.image_quad_pipeline_layout != 0 do vk.DestroyPipelineLayout(renderer.device, renderer.image_quad_pipeline_layout, nil)
	if renderer.scroll_indicator_pipeline != 0 do vk.DestroyPipeline(renderer.device, renderer.scroll_indicator_pipeline, nil)
	if renderer.scroll_indicator_pipeline_layout != 0 do vk.DestroyPipelineLayout(renderer.device, renderer.scroll_indicator_pipeline_layout, nil)
	if renderer.render_pass != 0 do vk.DestroyRenderPass(renderer.device, renderer.render_pass, nil)
	renderer.pipeline = 0
	renderer.pipeline_layout = 0
	renderer.padding_glow_pipeline = 0
	renderer.padding_glow_pipeline_layout = 0
	renderer.padding_glow_source_pipeline = 0
	renderer.padding_glow_background_pipeline = 0
	renderer.padding_glow_source_render_pass = 0
	renderer.osd_pipeline = 0
	renderer.osd_pipeline_layout = 0
	renderer.selection_pipeline = 0
	renderer.selection_pipeline_layout = 0
	renderer.scroll_indicator_pipeline = 0
	renderer.scroll_indicator_pipeline_layout = 0
	renderer.image_quad_pipeline = 0
	renderer.image_quad_pipeline_layout = 0
	renderer.render_pass = 0
	for image_view in renderer.image_views do vk.DestroyImageView(renderer.device, image_view, nil)
	delete(renderer.image_views)
	delete(renderer.swapchain_images)
	destroy_headless_target(renderer)
	if renderer.swapchain != 0 do vk.DestroySwapchainKHR(renderer.device, renderer.swapchain, nil)
	renderer.swapchain = 0
}

renderer_recreate_swapchain :: proc(
	renderer: ^Vulkan_Renderer,
	window: glfw.WindowHandle,
	framebuffer_readback: bool,
) -> (vk.Extent2D, bool) {
	width, height := glfw.GetFramebufferSize(window)
	if width <= 0 || height <= 0 do return {}, false
	vk_must(vk.DeviceWaitIdle(renderer.device), "waiting before swapchain recreation")
	for semaphore in renderer.render_finished do vk.DestroySemaphore(renderer.device, semaphore, nil)
	delete(renderer.render_finished)
	renderer.render_finished = nil
	destroy_swapchain_resources(renderer)
	create_swapchain(renderer, window, framebuffer_readback)
	create_swapchain_image_synchronization(renderer)
	return renderer.extent, true
}

application_recreate_swapchain :: proc(app: ^Grimalkin_App) -> bool {
	extent, recreated := renderer_recreate_swapchain(
		&app.renderer,
		app.window,
		app.framebuffer_readback,
	)
	if !recreated do return false
	resize_terminal_to_extent(app, extent)
	osd_prepare(app)
	create_swapchain_resources(&app.renderer)
	create_swapchain_frame_resources(&app.renderer, app.framebuffer_readback)
	app.capture_complete = false
	return true
}

destroy_frame_text_buffers :: proc(device: vk.Device, frame: ^Frame_Context) {
	destroy_buffer(device, &frame.image_placement_buffer)
	destroy_buffer(device, &frame.visual_buffer)
	destroy_buffer(device, &frame.cell_buffer)
	destroy_buffer(device, &frame.decoration_buffer)
	destroy_buffer(device, &frame.osd_cell_buffer)
	destroy_buffer(device, &frame.selection_mask_buffer)
	frame.descriptor_set = 0
	frame.osd_descriptor_set = 0
	frame.selection_descriptor_set = 0
	frame.image_placement_descriptor_set = 0
	frame.image_placement_capacity = 0
	frame.cell_capacity = 0
	frame.decoration_capacity = 0
	frame.osd_cell_capacity = 0
	frame.selection_mask_capacity = 0
	frame.visual_capacity = 0
	frame.visuals_uploaded = 0
}

destroy_vulkan :: proc(app: ^Grimalkin_App) {
	if app.device != nil {
		vk.DeviceWaitIdle(app.device)

		destroy_buffer(app.device, &app.staging_buffer)
		for &frame in app.frames {
			if frame.timestamp_pool != 0 do vk.DestroyQueryPool(app.device, frame.timestamp_pool, nil)
			destroy_frame_text_buffers(app.device, &frame)
			vk.DestroyFence(app.device, frame.in_flight, nil)
			vk.DestroySemaphore(app.device, frame.image_available, nil)
		}
		for semaphore in app.render_finished do vk.DestroySemaphore(app.device, semaphore, nil)
		delete(app.render_finished)
		delete(app.images_in_flight)
		delete(app.frames)
		destroy_texture_images(app.device, app.texture_images[:])
		delete(app.texture_images)
		if app.descriptor_pool != 0 do vk.DestroyDescriptorPool(app.device, app.descriptor_pool, nil)

		vk.DestroyCommandPool(app.device, app.command_pool, nil)
		vk.DestroyFence(app.device, app.upload_fence, nil)

		destroy_swapchain_resources(&app.renderer)
		if app.padding_glow_descriptor_layout != 0 {
			vk.DestroyDescriptorSetLayout(app.device, app.padding_glow_descriptor_layout, nil)
		}
		vk.DestroyDescriptorSetLayout(app.device, app.descriptor_layout, nil)
		if app.image_placement_descriptor_layout != 0 {
			vk.DestroyDescriptorSetLayout(app.device, app.image_placement_descriptor_layout, nil)
		}
		vk.DestroyDevice(app.device, nil)
	}

	if app.surface != 0 {
		vk.DestroySurfaceKHR(app.instance, app.surface, nil)
	}
	if app.debug_messenger != 0 {
		vk.DestroyDebugUtilsMessengerEXT(app.instance, app.debug_messenger, nil)
	}
	if app.instance != nil {
		vk.DestroyInstance(app.instance, nil)
	}
	delete(app.capture_path)
}

destroy_gpu_text_resources :: proc(app: ^Grimalkin_App) {
	for &frame in app.frames {
		destroy_frame_text_buffers(app.device, &frame)
	}
	destroy_texture_images(app.device, app.texture_images[:])
	delete(app.texture_images)
	app.texture_images = nil
	if app.descriptor_pool != 0 do vk.DestroyDescriptorPool(app.device, app.descriptor_pool, nil)
	app.descriptor_pool = 0
}

reset_text_resource_command_buffers :: proc(app: ^Grimalkin_App) {
	// DeviceWaitIdle makes submitted command buffers non-pending, but executable
	// command buffers still retain references to their recorded descriptor sets,
	// buffers, and images. Reset them before destroying those resources.
	if app.command_buffer != nil {
		vk_must(vk.ResetCommandBuffer(app.command_buffer, {}), "resetting texture commands before a text-resource rebuild")
	}
	for &frame in app.frames {
		if frame.command_buffer != nil {
			vk_must(vk.ResetCommandBuffer(frame.command_buffer, {}), "resetting frame commands before a text-resource rebuild")
		}
	}
}

apply_pending_settings :: proc(app: ^Grimalkin_App) {
	if app.settings_font_rebuild_pending || app.glyph_cache_reset_pending {
		font_index := -1
		primary_family: ^Font_Family
		if app.font_catalog != nil && app.font_catalog.automatic_index >= 0 {
			font_index, _ = font_catalog_resolve(
				app.font_catalog,
				font_family_setting_name(&app.settings.font_family),
			)
			if !app.font_catalog.environment_override && font_index >= 0 {
				primary_family = &app.font_catalog.families[font_index]
			}
		}
		pixel_height := scaled_font_pixel_height(app.settings.font_size, app.content_scale_y)
		render_config := application_settings_render_config(
			app.settings,
			app.detected_display_rotation,
		)
		if primary_family != nil &&
		   !font_family_validate_configured(primary_family, pixel_height, render_config) {
			app.settings.font_family = app.applied_settings.font_family
			app.settings.font_size = app.applied_settings.font_size
			app.settings.text_smoothing = app.applied_settings.text_smoothing
			app.settings.font_hinting = app.applied_settings.font_hinting
			app.settings.subpixel_layout = app.applied_settings.subpixel_layout
			app.settings.subpixel_rotation = app.applied_settings.subpixel_rotation
			app.settings.nerd_font_symbols = app.applied_settings.nerd_font_symbols
			app.settings_font_rebuild_pending = false
			delete(app.osd.font_error)
			app.osd.font_error = strings.clone("Font could not be loaded; previous font retained")
			app.osd.page = .Font_List
			app.osd.font_list_candidate = osd_font_applied_list_index(
				app.settings,
				app.font_catalog,
			)
			osd_prepare(app)
			app.redraw = true
			return
		}
		replacement := renderer_resources_init_configured(
			pixel_height,
			render_config,
			app.settings.nerd_font_symbols,
			primary_family,
		)
		replacement.textures.maximum_count = int(app.texture_capacity)
		properties: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(app.physical_device, &properties)
		renderer_resources_apply_texture_limits(
			&replacement,
			properties.limits.maxImageDimension2D,
			properties.limits.maxImageArrayLayers,
		)
		vk_must(vk.DeviceWaitIdle(app.device), "waiting to rebuild text resources")
		reset_text_resource_command_buffers(app)
		destroy_gpu_text_resources(app)
		if app.demo.demo_mode {
			for &atlas in app.demo.tile_atlases do raster_atlas_destroy(&atlas)
		}
		renderer_resources_destroy(&app.demo.resources)
		app.demo.resources = replacement
		app.active_font_index = font_index
		app.applied_settings = app.settings
		app.demo.compiler = {force_full_recompile = true}
		if app.demo.demo_mode {
			app.demo.tile_atlases[0] = raster_atlas_init(&app.demo.resources.textures, .Colour_RGBA8)
			app.demo.tile_atlases[1] = raster_atlas_init(&app.demo.resources.textures, .Colour_RGBA8)
		}
		app.settings_font_rebuild_pending = false
		app.glyph_cache_reset_pending = false
		app.settings_layout_pending = true
		resize_terminal_to_extent(app, app.extent, true)
		_ = refresh_terminal_display(app)
		osd_prepare(app)
		create_text_resources(app)
	}
	if app.settings_layout_pending {
		resize_terminal_to_extent(app, app.extent)
		app.settings_layout_pending = false
	}
	app.redraw = true
}
