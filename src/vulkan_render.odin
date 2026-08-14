package main

import "core:fmt"
import "core:time"
import "vendor:glfw"
import vk "vendor:vulkan"

read_gpu_draw_time :: proc(app: ^Grimalkin_App, frame: ^Frame_Context) -> (f64, bool) {
	if frame.timestamp_pool == 0 || !frame.timestamp_pending {
		return 0, false
	}
	timestamps: [2]u64
	vk_must(
		vk.GetQueryPoolResults(
			app.device,
			frame.timestamp_pool,
			0,
			2,
			size_of(timestamps),
			&timestamps,
			size_of(u64),
			{._64, .WAIT},
		),
		"reading benchmark timestamp queries",
	)
	frame.timestamp_pending = false

	counter_max := max(u64)
	if app.timestamp_bits < 64 {
		counter_max = (u64(1) << app.timestamp_bits) - 1
	}
	delta :=
		timestamps[1] - timestamps[0] if timestamps[1] >= timestamps[0] else (counter_max - timestamps[0]) + timestamps[1] + 1
	return f64(delta) * app.timestamp_period / 1_000_000.0, true
}

draw_frame_components :: proc(
	app: ^Grimalkin_App,
	cursor_opacity: u16,
	read_back_framebuffer := false,
	text_opacity := max(u16),
	scroll_indicator_opacity := u16(0),
) -> Benchmark_Frame_Sample {
	return draw_frame(
		app,
		{
			cursor_opacity = cursor_opacity,
			read_back_framebuffer = read_back_framebuffer,
			text_opacity = text_opacity,
			scroll_indicator_opacity = scroll_indicator_opacity,
		},
	)
}

draw_frame :: proc(app: ^Grimalkin_App, input: Render_Frame_Input) -> Benchmark_Frame_Sample {
	total_start := time.tick_now()
	frame := &app.frames[app.frame_index]
	vk_must(
		vk.WaitForFences(app.device, 1, &frame.in_flight, true, max(u64)),
		"waiting to reuse a frame context",
	)
	gpu_draw_ms, has_gpu_time := read_gpu_draw_time(app, frame)

	image_index: u32
	acquire_result := vk.AcquireNextImageKHR(
		app.device,
		app.swapchain,
		max(u64),
		frame.image_available,
		0,
		&image_index,
	)
	if acquire_result != .SUCCESS && acquire_result != .SUBOPTIMAL_KHR {
		if acquire_result == .ERROR_OUT_OF_DATE_KHR {
			_ = application_recreate_swapchain(app)
			return {}
		}
		fmt.panicf("acquiring a swapchain image failed: %v", acquire_result)
	}
	if app.images_in_flight[image_index] != 0 && app.images_in_flight[image_index] != frame.in_flight {
		vk_must(
			vk.WaitForFences(app.device, 1, &app.images_in_flight[image_index], true, max(u64)),
			"waiting for the acquired swapchain image",
		)
	}
	app.images_in_flight[image_index] = frame.in_flight

	cpu_start := time.tick_now()
	upload_stats := flush_text_resources(app, frame)
	vk_must(vk.ResetFences(app.device, 1, &frame.in_flight), "resetting an in-flight fence")
	vk_must(vk.ResetCommandBuffer(frame.command_buffer, {}), "resetting a frame command buffer")
	write_capture :=
		app.capture_path != "" && !app.capture_complete && glfw.GetTime() >= app.capture_deadline
	capture_frame := input.read_back_framebuffer || write_capture
	record_command_buffer(
		app,
		frame,
		image_index,
		input.cursor_opacity,
		input.text_opacity,
		input.scroll_indicator_opacity,
		capture_frame,
	)

	wait_stage := vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT}
	submit_info := vk.SubmitInfo {
		sType                = .SUBMIT_INFO,
		waitSemaphoreCount   = 1,
		pWaitSemaphores      = &frame.image_available,
		pWaitDstStageMask    = &wait_stage,
		commandBufferCount   = 1,
		pCommandBuffers      = &frame.command_buffer,
		signalSemaphoreCount = 1,
		pSignalSemaphores    = &app.render_finished[image_index],
	}
	vk_must(
		vk.QueueSubmit(app.graphics_queue, 1, &submit_info, frame.in_flight),
		"submitting the draw commands",
	)
	cpu_redraw_ms := time.duration_milliseconds(time.tick_since(cpu_start))
	if capture_frame {
		vk_must(
			vk.WaitForFences(app.device, 1, &frame.in_flight, true, max(u64)),
			"waiting for framebuffer capture",
		)
	}
	if write_capture {
		write_frame_capture(app)
		app.capture_complete = true
	}

	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &app.render_finished[image_index],
		swapchainCount     = 1,
		pSwapchains        = &app.swapchain,
		pImageIndices      = &image_index,
	}
	present_result := vk.QueuePresentKHR(app.present_queue, &present_info)
	if present_result != .SUCCESS && present_result != .SUBOPTIMAL_KHR {
		if present_result == .ERROR_OUT_OF_DATE_KHR {
			_ = application_recreate_swapchain(app)
		} else {
			fmt.panicf("presenting the swapchain image failed: %v", present_result)
		}
	}

	frame.timestamp_pending = frame.timestamp_pool != 0
	app.frame_index = (app.frame_index + 1) % app.active_frame_count
	return {
		cpu_redraw_ms = cpu_redraw_ms,
		gpu_draw_ms = gpu_draw_ms,
		total_ms = time.duration_milliseconds(time.tick_since(total_start)),
		has_gpu_time = has_gpu_time,
		cell_bytes_uploaded = upload_stats.cell_bytes,
		visual_bytes_uploaded = upload_stats.visual_bytes,
	}
}

record_padding_glow_source :: proc(
	app: ^Grimalkin_App,
	frame: ^Frame_Context,
	command_buffer: vk.CommandBuffer,
	text_area: vk.Rect2D,
	pipeline: vk.Pipeline,
	framebuffer: vk.Framebuffer,
) {
	clear_value := vk.ClearValue{}
	clear_value.color.float32 = {
		srgb_channel_to_linear(f32(6.0 / 255.0)),
		srgb_channel_to_linear(f32(9.0 / 255.0)),
		srgb_channel_to_linear(f32(18.0 / 255.0)),
		1,
	}
	render_pass_info := vk.RenderPassBeginInfo {
		sType = .RENDER_PASS_BEGIN_INFO,
		renderPass = app.padding_glow_source_render_pass,
		framebuffer = framebuffer,
		renderArea = {extent = app.extent},
		clearValueCount = 1,
		pClearValues = &clear_value,
	}
	vk.CmdBeginRenderPass(command_buffer, &render_pass_info, .INLINE)
	vk.CmdBindPipeline(command_buffer, .GRAPHICS, pipeline)
	viewport := vk.Viewport {
		x = f32(text_area.offset.x),
		y = f32(text_area.offset.y),
		width = f32(text_area.extent.width),
		height = f32(text_area.extent.height),
		maxDepth = 1,
	}
	vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
	source_scissor := text_area
	vk.CmdSetScissor(command_buffer, 0, 1, &source_scissor)
	vk.CmdBindDescriptorSets(
		command_buffer,
		.GRAPHICS,
		app.pipeline_layout,
		0,
		1,
		&frame.descriptor_set,
		0,
		nil,
	)
	push := Text_Layout_Push {
		grid = {
			u32(app.demo.grid.cols),
			u32(app.demo.grid.rows),
			app.demo.resources.cell_metrics.cell_width,
			app.demo.resources.cell_metrics.cell_height,
		},
		font = {
			app.demo.resources.cell_metrics.baseline,
			text_area.offset.x,
			text_area.offset.y,
			0,
		},
		cursor = {
			u32(app.demo.snapshot.cursor_x),
			u32(app.demo.snapshot.cursor_y),
			cursor_pack_push_word(
				app.demo.snapshot.cursor_style,
				false,
				0,
			),
			app.demo.snapshot.cursor_rgba,
		},
			effects = {u32(max(u16)), u32(app.settings.text_contrast), 0, 0},
	}
	vk.CmdPushConstants(
		command_buffer,
		app.pipeline_layout,
		{.FRAGMENT},
		0,
		u32(size_of(push)),
		&push,
	)
	vk.CmdDraw(command_buffer, 4, 1, 0, 0)
	vk.CmdEndRenderPass(command_buffer)
}

record_command_buffer :: proc(
	app: ^Grimalkin_App,
	frame: ^Frame_Context,
	image_index: u32,
	cursor_opacity: u16,
	text_opacity: u16,
	scroll_indicator_opacity: u16,
	capture_frame: bool,
) {
	command_buffer := frame.command_buffer
	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
	}
	vk_must(vk.BeginCommandBuffer(command_buffer, &begin_info), "beginning command recording")
	if frame.timestamp_pool != 0 {
		vk.CmdResetQueryPool(command_buffer, frame.timestamp_pool, 0, 2)
		vk.CmdWriteTimestamp(command_buffer, {.TOP_OF_PIPE}, frame.timestamp_pool, 0)
	}
	text_area := text_render_area(app)
	glow_enabled := app.settings.padding_glow != .Off && app.settings.padding > 0
	if glow_enabled {
			record_padding_glow_source(
			app,
			frame,
			command_buffer,
			text_area,
				app.padding_glow_source_pipeline,
				frame.padding_glow_source.framebuffer,
			)
		record_padding_glow_source(
			app,
			frame,
			command_buffer,
			text_area,
				app.padding_glow_background_pipeline,
				frame.padding_glow_background.framebuffer,
			)
	}

	clear_value := vk.ClearValue{}
	clear_red := f32(6.0 / 255.0)
	clear_green := f32(9.0 / 255.0)
	clear_blue := f32(18.0 / 255.0)
	if !app.manual_srgb_output {
		clear_red = srgb_channel_to_linear(clear_red)
		clear_green = srgb_channel_to_linear(clear_green)
		clear_blue = srgb_channel_to_linear(clear_blue)
	}
	clear_value.color.float32 = {clear_red, clear_green, clear_blue, 1.0}
	render_pass_info := vk.RenderPassBeginInfo {
		sType = .RENDER_PASS_BEGIN_INFO,
		renderPass = app.render_pass,
		framebuffer = app.framebuffers[image_index],
		renderArea = {extent = app.extent},
		clearValueCount = 1,
		pClearValues = &clear_value,
	}
	vk.CmdBeginRenderPass(command_buffer, &render_pass_info, .INLINE)
	if glow_enabled {
		regions := padding_glow_regions(app.extent, text_area)
		if regions.count > 0 {
			vk.CmdBindPipeline(command_buffer, .GRAPHICS, app.padding_glow_pipeline)
			full_viewport := vk.Viewport {
				width = f32(app.extent.width),
				height = f32(app.extent.height),
				maxDepth = 1,
			}
			vk.CmdSetViewport(command_buffer, 0, 1, &full_viewport)
			vk.CmdBindDescriptorSets(
				command_buffer,
				.GRAPHICS,
				app.padding_glow_pipeline_layout,
				0,
				1,
				&frame.padding_glow_descriptor_set,
				0,
				nil,
			)
			glow_push := Padding_Glow_Push {
				frame = {
					app.extent.width,
					app.extent.height,
					app.manual_srgb_output ? 1 : 0,
					u32(app.settings.padding_glow),
				},
				text = {
					text_area.offset.x,
					text_area.offset.y,
					i32(text_area.extent.width),
					i32(text_area.extent.height),
				},
				sampling = {
					app.demo.resources.cell_metrics.cell_width,
					app.demo.resources.cell_metrics.cell_height,
					u32(app.demo.grid.cols),
					u32(app.demo.grid.rows),
				},
				style = {pack_rgba8(6, 9, 18, 255), 0, 0, 0},
			}
			vk.CmdPushConstants(
				command_buffer,
				app.padding_glow_pipeline_layout,
				{.FRAGMENT},
				0,
				u32(size_of(glow_push)),
				&glow_push,
			)
			for index in 0 ..< regions.count {
				vk.CmdSetScissor(command_buffer, 0, 1, &regions.rects[index])
				vk.CmdDraw(command_buffer, 4, 1, 0, 0)
			}
		}
	}

	vk.CmdBindPipeline(command_buffer, .GRAPHICS, app.pipeline)
	viewport := vk.Viewport {
		x        = f32(text_area.offset.x),
		y        = f32(text_area.offset.y),
		width    = f32(text_area.extent.width),
		height   = f32(text_area.extent.height),
		maxDepth = 1.0,
	}
	vk.CmdSetViewport(command_buffer, 0, 1, &viewport)

	vk.CmdSetScissor(command_buffer, 0, 1, &text_area)
	vk.CmdBindDescriptorSets(
		command_buffer,
		.GRAPHICS,
		app.pipeline_layout,
		0,
		1,
		&frame.descriptor_set,
		0,
		nil,
	)
	push := Text_Layout_Push {
		grid   = {
			u32(app.demo.grid.cols),
			u32(app.demo.grid.rows),
			app.demo.resources.cell_metrics.cell_width,
			app.demo.resources.cell_metrics.cell_height,
		},
		font   = {
			app.demo.resources.cell_metrics.baseline,
			text_area.offset.x,
			text_area.offset.y,
			app.manual_srgb_output ? 1 : 0,
		},
		cursor = {
			u32(app.demo.snapshot.cursor_x),
			u32(app.demo.snapshot.cursor_y),
			cursor_pack_push_word(
				app.demo.snapshot.cursor_style,
				app.demo.snapshot.cursor_visible,
				cursor_opacity,
			),
			app.demo.snapshot.cursor_rgba,
		},
		effects = {u32(text_opacity), u32(app.settings.text_contrast), 0, 0},
	}
	vk.CmdPushConstants(
		command_buffer,
		app.pipeline_layout,
		{.FRAGMENT},
		0,
		u32(size_of(push)),
		&push,
	)
	vk.CmdDraw(command_buffer, 4, 1, 0, 0)
	if app.selection.active && selection_mask_has_any(&app.selection) {
		vk.CmdBindPipeline(command_buffer, .GRAPHICS, app.selection_pipeline)
		vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
		vk.CmdSetScissor(command_buffer, 0, 1, &text_area)
		vk.CmdBindDescriptorSets(
			command_buffer,
			.GRAPHICS,
			app.selection_pipeline_layout,
			0,
			1,
			&frame.selection_descriptor_set,
			0,
			nil,
		)
		selection_push := Selection_Push {
			frame = {
				app.extent.width,
				app.extent.height,
				app.manual_srgb_output ? 1 : 0,
				u32(app.settings.selection_style),
			},
			grid = {
				u32(app.demo.grid.cols),
				u32(app.demo.grid.rows),
				app.demo.resources.cell_metrics.cell_width,
				app.demo.resources.cell_metrics.cell_height,
			},
			area = {
				text_area.offset.x,
				text_area.offset.y,
				i32(text_area.extent.width),
				i32(text_area.extent.height),
			},
			render = {
				0,
				u32(max(app.content_scale_x, 1) * 65536.0 + 0.5),
				u32(max(app.content_scale_y, 1) * 65536.0 + 0.5),
				0,
			},
		}
		vk.CmdPushConstants(
			command_buffer,
			app.selection_pipeline_layout,
			{.FRAGMENT},
			0,
			u32(size_of(selection_push)),
			&selection_push,
		)
		vk.CmdDraw(command_buffer, 4, 1, 0, 0)
	}
	indicator := scroll_indicator_geometry(
		app.extent,
		text_area,
		app.demo.snapshot.scroll_total_rows,
		app.demo.snapshot.scroll_offset_rows,
		app.demo.snapshot.scroll_visible_rows,
		app.content_scale_x,
		app.content_scale_y,
	)
	if scroll_indicator_opacity > 0 && indicator.valid {
		vk.CmdBindPipeline(command_buffer, .GRAPHICS, app.scroll_indicator_pipeline)
		indicator_viewport := vk.Viewport {
			x = f32(indicator.rect.offset.x),
			y = f32(indicator.rect.offset.y),
			width = f32(indicator.rect.extent.width),
			height = f32(indicator.rect.extent.height),
			maxDepth = 1,
		}
		vk.CmdSetViewport(command_buffer, 0, 1, &indicator_viewport)
		vk.CmdSetScissor(command_buffer, 0, 1, &indicator.rect)
		indicator_push := Scroll_Indicator_Push {
			rect = {
				indicator.rect.offset.x,
				indicator.rect.offset.y,
				i32(indicator.rect.extent.width),
				i32(indicator.rect.extent.height),
			},
			style = {
				SCROLL_INDICATOR_COLOUR,
				u32(scroll_indicator_opacity),
				app.manual_srgb_output ? 1 : 0,
				0,
			},
		}
		vk.CmdPushConstants(
			command_buffer,
			app.scroll_indicator_pipeline_layout,
			{.FRAGMENT},
			0,
			u32(size_of(indicator_push)),
			&indicator_push,
		)
		vk.CmdDraw(command_buffer, 4, 1, 0, 0)
	}
	if app.osd.visible {
		vk.CmdBindPipeline(command_buffer, .GRAPHICS, app.osd_pipeline)
		full_viewport := vk.Viewport{width = f32(app.extent.width), height = f32(app.extent.height), maxDepth = 1}
		full_scissor := vk.Rect2D{extent = app.extent}
		vk.CmdSetViewport(command_buffer, 0, 1, &full_viewport)
		vk.CmdSetScissor(command_buffer, 0, 1, &full_scissor)
		vk.CmdBindDescriptorSets(command_buffer, .GRAPHICS, app.osd_pipeline_layout, 0, 1, &frame.osd_descriptor_set, 0, nil)
		metrics := app.demo.resources.cell_metrics
		panel := osd_panel_rect(app.extent.width, app.extent.height, metrics.cell_width, metrics.cell_height, app.osd.cols, app.osd.rows)
		content_width := u32(app.osd.cols) * metrics.cell_width
		content_height := u32(app.osd.rows) * metrics.cell_height
		content_x := panel.offset.x + i32((panel.extent.width - content_width) / 2)
		content_y := panel.offset.y + i32((panel.extent.height - content_height) / 2)
		osd_push := Osd_Push {
			frame = {
				app.extent.width,
				app.extent.height,
				app.manual_srgb_output ? 1 : 0,
				u32(app.settings.text_contrast),
			},
			panel = {panel.offset.x, panel.offset.y, i32(panel.extent.width), i32(panel.extent.height)},
			grid = {u32(app.osd.cols), u32(app.osd.rows), metrics.cell_width, metrics.cell_height},
			font = {i32(metrics.baseline), content_x, content_y, 0},
		}
		vk.CmdPushConstants(command_buffer, app.osd_pipeline_layout, {.FRAGMENT}, 0, u32(size_of(osd_push)), &osd_push)
		vk.CmdDraw(command_buffer, 4, 1, 0, 0)
	}
	vk.CmdEndRenderPass(command_buffer)
	if capture_frame {
		record_frame_capture(app, command_buffer, image_index)
	}
	if frame.timestamp_pool != 0 {
		vk.CmdWriteTimestamp(command_buffer, {.BOTTOM_OF_PIPE}, frame.timestamp_pool, 1)
	}

	vk_must(vk.EndCommandBuffer(command_buffer), "ending command recording")
}
