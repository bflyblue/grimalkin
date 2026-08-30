package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "vendor:glfw"
import vk "vendor:vulkan"

scaled_font_pixel_height :: proc(logical_height: u16, content_scale: f32) -> u16 {
	return u16(max(f32(1), f32(logical_height) * content_scale + 0.5))
}

logical_window_dimension :: proc(physical_cell_size, cells, padding: u32, content_scale: f32) -> i32 {
	scale := max(f32(1), content_scale)
	return i32(f32(physical_cell_size * cells + padding * 2) / scale + 0.5)
}

detect_display_rotation :: proc(window: glfw.WindowHandle = nil) -> Display_Rotation {
	degrees := grimalkin_display_rotation(rawptr(window))
	switch degrees {
	case 0:   return .Degrees_0
	case 90:  return .Degrees_90
	case 180: return .Degrees_180
	case 270: return .Degrees_270
	}
	return .Unknown
}

refresh_display_rotation :: proc(app: ^Grimalkin_App) {
	detected := detect_display_rotation(app.window)
	if detected == app.detected_display_rotation do return
	before := application_settings_render_config(app.settings, app.detected_display_rotation)
	after := application_settings_render_config(app.settings, detected)
	app.detected_display_rotation = detected
	if before != after do app.settings_font_rebuild_pending = true
	osd_prepare(app)
	app.redraw = true
}

sample_render_frame_input :: proc(
	app: ^Grimalkin_App,
	now: f64,
) -> (Render_Frame_Input, Cursor_Animation_Sample, Scroll_Indicator_Sample) {
	cursor := sample_cursor_animation(app, now)
	indicator := scroll_indicator_sample(
		&app.scroll_indicator,
		now,
		app.demo.snapshot.viewport_active,
	)
	app.cursor_animation.next_sample_at = cursor.next_sample_at
	return {
		cursor_opacity = cursor.opacity,
		text_opacity = cursor.text_opacity,
		scroll_indicator_opacity = indicator.opacity,
	}, cursor, indicator
}

run_grimalkin :: proc(mode: Grimalkin_Run_Mode) -> bool {
	demo_mode := mode == .Demo
	cursor_gpu_test := mode == .Cursor_Gpu_Test
	if cursor_gpu_test {
		// The GPU suite renders into an image it owns and never presents, so it
		// asks GLFW for its null backend: no display server is involved, and the
		// window below exists only to keep the shared setup path intact.
		glfw.InitHint(glfw.PLATFORM, glfw.PLATFORM_NULL)
	}
	if !glfw.Init() {
		description, code := glfw.GetError()
		fmt.eprintfln("grimalkin: GLFW initialization failed (%d): %s", code, description)
		return false
	}
	defer glfw.Terminate()
	// The null backend reports no monitors, and the suite pins scaling anyway so
	// that captured pixel positions do not depend on the host display.
	xscale, yscale := f32(1), f32(1)
	if !cursor_gpu_test {
		xscale, yscale = glfw.GetMonitorContentScale(glfw.GetPrimaryMonitor())
	}
	xscale = max(f32(1), xscale)
	yscale = max(f32(1), yscale)
	settings_path, has_settings_path := settings_config_path()
	settings := application_settings_default()
	if cursor_gpu_test {
		// GPU tests must be deterministic and must never read or overwrite the
		// interactive user's persisted settings.
		settings_path = ""
		has_settings_path = false
	} else if has_settings_path {
		settings, _ = settings_load(settings_path)
	}
	detected_rotation := Display_Rotation.Degrees_0 if cursor_gpu_test else detect_display_rotation()
	font_pixel_height := scaled_font_pixel_height(settings.font_size, yscale)

	// Spawn before font discovery and shaping libraries have an opportunity to
	// create helper threads. The forkpty child path can then exec immediately
	// without inheriting third-party library locks.
	session := Terminal_Session{}
	if !demo_mode && !cursor_gpu_test {
		started: bool
		session, started = terminal_session_init(GRID_COLUMNS, GRID_ROWS, 10, 22)
		if !started do return false
	}

	font_catalog, catalog_ok := font_catalog_init()
	defer font_catalog_destroy(&font_catalog)
	font_index := -1
	settings_repaired := false
	if catalog_ok {
		requested_font := font_family_setting_name(&settings.font_family)
		missing_font := false
		font_index, settings_repaired, missing_font = font_catalog_resolve_saved_preference(
			&font_catalog,
			&settings.font_family,
		)
		if missing_font {
			fmt.eprintfln(
				"Grimalkin could not use saved font family %s; using Automatic (%s)",
				requested_font,
				font_catalog.families[font_catalog.automatic_index].name,
			)
		}
	} else {
		fmt.eprintfln(
			"Grimalkin could not select a system monospaced font from %d fixed-width families (automatic index %d)",
			len(font_catalog.families),
			font_catalog.automatic_index,
		)
	}
	primary_family: ^Font_Family
	if catalog_ok && !font_catalog.environment_override && font_index >= 0 {
		primary_family = &font_catalog.families[font_index]
	}

	render_config := application_settings_render_config(settings, detected_rotation)
	demo := grimalkin_demo_init_configured(font_pixel_height, render_config, settings.nerd_font_symbols, primary_family, settings.colour_theme) if demo_mode else grimalkin_terminal_init_configured(
		font_pixel_height,
		render_config,
		settings.nerd_font_symbols,
		primary_family,
		settings.kitty_image_storage_mb,
		settings.scrollback_limit_bytes,
		settings.scrollback_limit_lines,
		settings.colour_theme,
	)
	demo.session = session
	defer grimalkin_demo_destroy(&demo)
	if !demo_mode && !cursor_gpu_test {
		_ = terminal_session_resize(
			&demo.session,
			GRID_COLUMNS,
			GRID_ROWS,
			demo.resources.cell_metrics.cell_width,
			demo.resources.cell_metrics.cell_height,
		)
		terminal_core_set_write_pty(
			&demo.terminal,
			terminal_session_write_pty,
			rawptr(&demo.session),
		)
	}
	when BENCHMARK_MODE {
		grimalkin_demo_prepare_benchmark(&demo)
	}

	if !glfw.VulkanSupported() {
		description, code := glfw.GetError()
		fmt.eprintfln("grimalkin: GLFW could not find a Vulkan loader (%d): %s", code, description)
		return false
	}

	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	glfw.WindowHint(glfw.RESIZABLE, glfw.TRUE)
	glfw.WindowHint(
		glfw.DECORATED,
		settings.window_style == .Frameless ? glfw.FALSE : glfw.TRUE,
	)
	if cursor_gpu_test do glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)

	window_width := logical_window_dimension(
		demo.resources.cell_metrics.cell_width,
		GRID_COLUMNS,
		u32(f32(settings.padding) * xscale + 0.5),
		xscale,
	)
	window_height := logical_window_dimension(
		demo.resources.cell_metrics.cell_height,
		GRID_ROWS,
		u32(f32(settings.padding) * yscale + 0.5),
		yscale,
	)
	fmt.printfln(
		"Display scale: %.2fx%.2f; font atlas: %d px; cell: %dx%d physical pixels",
		xscale,
		yscale,
		font_pixel_height,
		demo.resources.cell_metrics.cell_width,
		demo.resources.cell_metrics.cell_height,
	)
	app := Grimalkin_App {
		demo                 = &demo,
		redraw               = true,
		focused              = true,
		framebuffer_readback = cursor_gpu_test,
		cursor_gpu_test      = cursor_gpu_test,
		headless             = cursor_gpu_test,
		settings             = settings,
		applied_settings     = settings,
		font_catalog         = &font_catalog,
		active_font_index    = font_index,
		settings_path        = settings_path,
		settings_save_pending = settings_repaired,
		settings_save_deadline = settings_repaired ? glfw.GetTime() + 0.4 : 0,
		content_scale_x      = xscale,
		content_scale_y      = yscale,
		detected_display_rotation = detected_rotation,
		compression          = scrollback_compression_scheduler_init(settings.scrollback_compression),
	}
	defer osd_state_destroy(&app.osd)
	defer selection_destroy(&app.selection)
	defer delete(app.pending_paste)
	defer delete(app.settings_path)
	if capture_path := os.get_env("GRIMALKIN_CAPTURE_PATH", context.temp_allocator);
	   capture_path != "" {
		app.capture_path = strings.clone(capture_path)
		app.framebuffer_readback = true
		if delay_text := os.get_env("GRIMALKIN_CAPTURE_DELAY_MS", context.temp_allocator);
		   delay_text != "" {
			if delay_ms, ok := strconv.parse_int(delay_text); ok && delay_ms > 0 {
				app.capture_deadline = glfw.GetTime() + f64(delay_ms) / 1000.0
			}
		}
		app.capture_exit = os.get_env("GRIMALKIN_CAPTURE_EXIT", context.temp_allocator) == "1"
	}
	app.window = glfw.CreateWindow(window_width, window_height, "Grimalkin", nil, nil)
	if app.window == nil {
		description, code := glfw.GetError()
		fmt.eprintfln("grimalkin: window creation failed (%d): %s", code, description)
		return false
	}
	app.windowed_geometry = window_client_geometry(app.window)
	app.windowed_geometry_valid = app.windowed_geometry.width > 0 && app.windowed_geometry.height > 0
	app.selection_text_cursor = glfw.CreateStandardCursor(glfw.IBEAM_CURSOR)
	app.selection_block_cursor = glfw.CreateStandardCursor(glfw.CROSSHAIR_CURSOR)
	app.url_hover_cursor = glfw.CreateStandardCursor(glfw.POINTING_HAND_CURSOR)
	defer if app.selection_text_cursor != nil do glfw.DestroyCursor(app.selection_text_cursor)
	defer if app.selection_block_cursor != nil do glfw.DestroyCursor(app.selection_block_cursor)
	defer if app.url_hover_cursor != nil do glfw.DestroyCursor(app.url_hover_cursor)
	defer url_hover_destroy(&app.url_hover)
	when ODIN_OS == .Darwin {
		if grimalkin_macos_configure_window(
			rawptr(app.window),
			settings.window_style == .Frameless ? 1 : 0,
		) == 0 {
			fmt.eprintln("macOS could not configure native window behavior")
		}
	}
	when ODIN_OS == .Windows {
		grimalkin_set_window_icon(rawptr(app.window))
		apply_window_corner_preference(&app)
	}
	defer glfw.DestroyWindow(app.window)
	glfw.SetWindowUserPointer(app.window, &app)
	glfw.SetInputMode(app.window, glfw.LOCK_KEY_MODS, 1)
	glfw.SetKeyCallback(app.window, key_callback)
	glfw.SetCharCallback(app.window, char_callback)
	glfw.SetMouseButtonCallback(app.window, mouse_button_callback)
	glfw.SetCursorPosCallback(app.window, cursor_position_callback)
	glfw.SetCursorEnterCallback(app.window, cursor_enter_callback)
	glfw.SetScrollCallback(app.window, scroll_callback)
	glfw.SetFramebufferSizeCallback(app.window, framebuffer_size_callback)
	glfw.SetWindowSizeCallback(app.window, window_size_callback)
	glfw.SetWindowPosCallback(app.window, window_position_callback)
	glfw.SetWindowRefreshCallback(app.window, window_refresh_callback)
	glfw.SetWindowFocusCallback(app.window, window_focus_callback)
	glfw.SetWindowContentScaleCallback(app.window, window_content_scale_callback)
	reset_cursor_animation(&app, glfw.GetTime())
	if !cursor_gpu_test {
		window_rotation := detect_display_rotation(app.window)
		if application_settings_render_config(settings, window_rotation) != render_config {
			app.settings_font_rebuild_pending = true
		}
		app.detected_display_rotation = window_rotation
	}

	if !init_vulkan(&app) do return false
	defer destroy_vulkan(&app)
	defer settings_flush(&app)
	scrollback_compression_capture_baseline(&app)

	benchmark_samples := Benchmark_Samples{}
	defer benchmark_samples_destroy(&benchmark_samples)
	frames_rendered := 0
	if cursor_gpu_test {
		run_cursor_gpu_tests(&app)
		return true
	}
	when BENCHMARK_MODE {
		for !glfw.WindowShouldClose(app.window) {
			// Every context.temp_allocator value produced by initialization or the
			// previous frame is scratch. None of it is retained by app or demo.
			mem.free_all(context.temp_allocator)
			glfw.PollEvents()
			frame_time := glfw.GetTime()
			input, _, _ := sample_render_frame_input(&app, frame_time)
			sample := draw_frame(&app, input)
			frames_rendered += 1
			if frames_rendered > BENCHMARK_WARMUP_FRAMES {
				benchmark_add_sample(&benchmark_samples, sample)
			}
			if len(benchmark_samples.total) >= BENCHMARK_SAMPLE_FRAMES {
				benchmark_print(&app, &benchmark_samples)
				break
			}
		}
	} else {
		for !glfw.WindowShouldClose(app.window) {
			// Reclaim shaping, dirty-range, descriptor, and upload scratch from
			// the previous pass before callbacks or terminal output allocate more.
			mem.free_all(context.temp_allocator)
			drain_budget_exhausted := false
			if !demo.demo_mode {
				drain := terminal_session_drain(&demo.session, &demo.terminal)
				drain_budget_exhausted = drain.budget_exhausted
				if drain.bytes > 0 {
					_ = refresh_terminal_display(&app)
					selection_snapshot_updated(&app)
					app.redraw = true
				}
				process_terminal_clipboard(&app)
			}
			scrollback_compression_service(&app, glfw.GetTime())
			if app.display_rotation_check_pending &&
			   glfw.GetTime() >= app.display_rotation_check_deadline {
				app.display_rotation_check_pending = false
				refresh_display_rotation(&app)
			}
			if app.framebuffer_dirty {
				_ = application_recreate_swapchain(&app)
				app.framebuffer_dirty = false
				app.redraw = true
			}
			if app.gpu_rebuild_pending {
				app.gpu_rebuild_pending = false
				settings_flush(&app)
				if !rebuild_vulkan_device(&app) do return false
				app.applied_settings.gpu_preference = app.settings.gpu_preference
			}
			apply_pending_settings(&app)
			if app.settings_save_pending && glfw.GetTime() >= app.settings_save_deadline do settings_flush(&app)
			if app.osd.font_search != "" && glfw.GetTime() >= app.osd.font_search_deadline {
				delete(app.osd.font_search)
				app.osd.font_search = ""
				osd_prepare(&app)
				app.redraw = true
			}
			if !demo.demo_mode {
				status := terminal_session_status(&demo.session)
				if status.io_error != 0 {
					fmt.eprintfln("terminal session I/O failed (system error %d)", status.io_error)
					break
				}
				if status.exited != 0 && status.output_eof != 0 {
					if status.signaled != 0 {
						fmt.eprintfln("shell terminated by signal %d", status.signal_number)
					} else if status.exit_code != 0 {
						fmt.eprintfln("shell exited with status %d", status.exit_code)
					}
					break
				}
			}
			if app.minimized {
				app.redraw = false
				if drain_budget_exhausted {
					glfw.PollEvents()
					continue
				}
				wait_deadline := scrollback_compression_wait_deadline(app.compression)
				if wait_deadline != max(f64) {
					timeout := max(0.001, wait_deadline - glfw.GetTime())
					glfw.WaitEventsTimeout(timeout)
				} else {
					glfw.WaitEvents()
				}
				continue
			}
			now := glfw.GetTime()
			if app.selection.dragging && app.selection.autoscroll_rows != 0 &&
			   now >= app.selection.autoscroll_next_at {
				scroll_terminal_rows(&app, app.selection.autoscroll_rows)
				x, y := glfw.GetCursorPos(app.window)
				selection_extend(
					&app.selection,
					&app.demo.terminal,
					&app.demo.snapshot,
					mouse_selection_point(&app, x, y),
					x,
					y,
				)
				app.selection.autoscroll_next_at = now + 1.0 / 30.0
			}
			capture_waiting := app.capture_path != "" && !app.capture_complete
			if capture_waiting && now >= app.capture_deadline {
				app.redraw = true
			}
			cursor_sample := sample_cursor_animation(&app, now)
			if cursor_sample.animated && now >= app.cursor_animation.next_sample_at {
				app.redraw = true
			}
			indicator_due := app.scroll_indicator.revealed &&
				app.scroll_indicator.next_sample_at != max(f64) &&
				now >= app.scroll_indicator.next_sample_at
			indicator_sample := scroll_indicator_sample(
				&app.scroll_indicator,
				now,
				demo.snapshot.viewport_active,
			)
			if indicator_due do app.redraw = true
			if app.redraw {
				frame_time := glfw.GetTime()
				input: Render_Frame_Input
				input, cursor_sample, indicator_sample = sample_render_frame_input(&app, frame_time)
				_ = draw_frame(&app, input)
				app.redraw = false
				frames_rendered += 1
				if app.capture_complete && app.capture_exit do break
				if DEMO_FRAME_LIMIT > 0 && frames_rendered >= DEMO_FRAME_LIMIT do break
			}
			wait_deadline := max(f64)
			if cursor_sample.animated {
				wait_deadline = min(wait_deadline, app.cursor_animation.next_sample_at)
			}
			if capture_waiting {
				wait_deadline = min(wait_deadline, app.capture_deadline)
			}
			if app.scroll_indicator.revealed && app.scroll_indicator.next_sample_at != max(f64) {
				wait_deadline = min(wait_deadline, app.scroll_indicator.next_sample_at)
			}
			if app.settings_save_pending {
				wait_deadline = min(wait_deadline, app.settings_save_deadline)
			}
			if app.display_rotation_check_pending {
				wait_deadline = min(wait_deadline, app.display_rotation_check_deadline)
			}
			if app.osd.font_search != "" {
				wait_deadline = min(wait_deadline, app.osd.font_search_deadline)
			}
			if app.selection.dragging && app.selection.autoscroll_rows != 0 {
				wait_deadline = min(wait_deadline, app.selection.autoscroll_next_at)
			}
			wait_deadline = scrollback_compression_wait_deadline(app.compression, wait_deadline)
			if drain_budget_exhausted {
				// A saturated PTY still yields to window/input callbacks once per
				// chunk instead of turning the drain loop into an event-loop stall.
				glfw.PollEvents()
			} else if wait_deadline != max(f64) {
				timeout := max(0.001, wait_deadline - glfw.GetTime())
				glfw.WaitEventsTimeout(timeout)
			} else {
				glfw.WaitEvents()
			}
		}
	}

	vk_must(vk.DeviceWaitIdle(app.device), "waiting for the device to become idle")
	return true
}
