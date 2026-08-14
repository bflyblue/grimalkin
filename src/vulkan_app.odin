package main

import "base:runtime"
import c "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:sort"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import "vendor:glfw"
import vk "vendor:vulkan"

when ODIN_OS == .Windows {
	foreign import png_shim {"system:grimalkin_png.obj", "system:libpng16.lib"}
} else {
	foreign import png_shim {"system:grimalkin_png", "system:png16"}
}

@(default_calling_convention = "c")
foreign png_shim {
	grimalkin_write_png_rgba :: proc(path: cstring, width, height: u32, pixels: [^]u8, stride: c.size_t) -> c.int ---
}

ENABLE_VALIDATION :: #config(ENABLE_VALIDATION, ODIN_DEBUG)
DEMO_FRAME_LIMIT :: #config(DEMO_FRAME_LIMIT, 0)
BENCHMARK_MODE :: #config(BENCHMARK_MODE, false)
BENCHMARK_WARMUP_FRAMES :: #config(BENCHMARK_WARMUP_FRAMES, 60)
BENCHMARK_SAMPLE_FRAMES :: #config(BENCHMARK_SAMPLE_FRAMES, 300)
MAX_TEXTURE_RESOURCES_CAP :: u32(1024)
MAX_FRAMES_IN_FLIGHT :: 3
WINDOW_PADDING_PX :: u32(0)
PADDING_GLOW_SOURCE_FORMAT :: vk.Format.R16G16B16A16_SFLOAT

#assert(BENCHMARK_WARMUP_FRAMES >= 0)
#assert(BENCHMARK_SAMPLE_FRAMES > 0)

VERTEX_SHADER :: #load("shaders/text.vert.spv")
FRAGMENT_SHADER :: #load("shaders/text.frag.spv")
OSD_VERTEX_SHADER :: #load("shaders/osd.vert.spv")
OSD_FRAGMENT_SHADER :: #load("shaders/osd.frag.spv")
PADDING_GLOW_VERTEX_SHADER :: #load("shaders/padding_glow.vert.spv")
PADDING_GLOW_FRAGMENT_SHADER :: #load("shaders/padding_glow.frag.spv")
PADDING_GLOW_BACKGROUND_FRAGMENT_SHADER :: #load("shaders/padding_glow_background.frag.spv")
SCROLL_INDICATOR_FRAGMENT_SHADER :: #load("shaders/scroll_indicator.frag.spv")
SELECTION_VERTEX_SHADER :: #load("shaders/selection.vert.spv")
SELECTION_FRAGMENT_SHADER :: #load("shaders/selection.frag.spv")

Gpu_Buffer :: struct {
	handle: vk.Buffer,
	memory: vk.DeviceMemory,
	size:   vk.DeviceSize,
	mapped: rawptr,
}

Gpu_Texture_Image :: struct {
	slot_generation: u64,
	image:      vk.Image,
	memory:     vk.DeviceMemory,
	view:       vk.ImageView,
	sampler:    vk.Sampler,
	width:      u32,
	height:     u32,
	layers:     u32,
	format:     Texture_Format,
	encoding:   Texture_Encoding,
	alpha_mode: Texture_Alpha_Mode,
	filter:     Texture_Filter,
	layout:     vk.ImageLayout,
}

Benchmark_Frame_Sample :: struct {
	cpu_redraw_ms:         f64,
	gpu_draw_ms:           f64,
	total_ms:              f64,
	has_gpu_time:          bool,
	cell_bytes_uploaded:   u64,
	visual_bytes_uploaded: u64,
}

Benchmark_Samples :: struct {
	cpu_redraw:            [dynamic]f64,
	gpu_draw:              [dynamic]f64,
	total:                 [dynamic]f64,
	cell_bytes_uploaded:   u64,
	visual_bytes_uploaded: u64,
}

Gpu_Upload_Stats :: struct {
	cell_bytes:   u64,
	visual_bytes: u64,
}

Frame_Context :: struct {
	descriptor_set:       vk.DescriptorSet,
	osd_descriptor_set:   vk.DescriptorSet,
	selection_descriptor_set: vk.DescriptorSet,
	padding_glow_descriptor_set: vk.DescriptorSet,
	padding_glow_source_image: vk.Image,
	padding_glow_source_memory: vk.DeviceMemory,
	padding_glow_source_view: vk.ImageView,
	padding_glow_source_attachment_view: vk.ImageView,
	padding_glow_source_framebuffer: vk.Framebuffer,
	padding_glow_background_image: vk.Image,
	padding_glow_background_memory: vk.DeviceMemory,
	padding_glow_background_view: vk.ImageView,
	padding_glow_background_attachment_view: vk.ImageView,
	padding_glow_background_framebuffer: vk.Framebuffer,
	cell_buffer:          Gpu_Buffer,
	cell_capacity:        int,
	decoration_buffer:    Gpu_Buffer,
	decoration_capacity:  int,
	osd_cell_buffer:      Gpu_Buffer,
	osd_cell_capacity:    int,
	selection_mask_buffer: Gpu_Buffer,
	selection_mask_capacity: int,
	visual_buffer:        Gpu_Buffer,
	visual_capacity:      int,
	visuals_uploaded:     int,
	grid_generation:      u64,
	visual_generation:    u64,
	osd_generation:       u64,
	selection_generation: u64,
	command_buffer:       vk.CommandBuffer,
	image_available:      vk.Semaphore,
	in_flight:            vk.Fence,
	timestamp_pool:       vk.QueryPool,
	timestamp_pending:    bool,
}

Benchmark_Summary :: struct {
	minimum: f64,
	median:  f64,
	p95:     f64,
	mean:    f64,
	maximum: f64,
}

Queue_Families :: struct {
	graphics:     u32,
	present:      u32,
	has_graphics: bool,
	has_present:  bool,
}

Swapchain_Support :: struct {
	capabilities:  vk.SurfaceCapabilitiesKHR,
	formats:       []vk.SurfaceFormatKHR,
	present_modes: []vk.PresentModeKHR,
}

Vulkan_App :: struct {
	demo:               ^Grimalkin_Demo,
	window:             glfw.WindowHandle,
	instance:           vk.Instance,
	debug_messenger:    vk.DebugUtilsMessengerEXT,
	surface:            vk.SurfaceKHR,
	physical_device:    vk.PhysicalDevice,
	texture_capacity:   u32,
	device:             vk.Device,
	graphics_queue:     vk.Queue,
	present_queue:      vk.Queue,
	queue_families:     Queue_Families,
	swapchain:          vk.SwapchainKHR,
	swapchain_images:   []vk.Image,
	image_views:        []vk.ImageView,
	surface_format:     vk.SurfaceFormatKHR,
	manual_srgb_output: bool,
	extent:             vk.Extent2D,
	render_pass:        vk.RenderPass,
	pipeline_layout:    vk.PipelineLayout,
	pipeline:           vk.Pipeline,
	osd_pipeline_layout: vk.PipelineLayout,
	osd_pipeline:        vk.Pipeline,
	padding_glow_pipeline_layout: vk.PipelineLayout,
	padding_glow_pipeline:        vk.Pipeline,
	padding_glow_source_render_pass: vk.RenderPass,
	padding_glow_source_pipeline: vk.Pipeline,
	padding_glow_background_pipeline: vk.Pipeline,
	padding_glow_descriptor_layout: vk.DescriptorSetLayout,
	padding_glow_descriptor_pool: vk.DescriptorPool,
	padding_glow_sampler: vk.Sampler,
	scroll_indicator_pipeline_layout: vk.PipelineLayout,
	scroll_indicator_pipeline:        vk.Pipeline,
	selection_pipeline_layout: vk.PipelineLayout,
	selection_pipeline:        vk.Pipeline,
	descriptor_layout:  vk.DescriptorSetLayout,
	descriptor_pool:    vk.DescriptorPool,
	staging_buffer:     Gpu_Buffer,
	texture_images:     [dynamic]Gpu_Texture_Image,
	framebuffers:       []vk.Framebuffer,
	command_pool:       vk.CommandPool,
	command_buffer:     vk.CommandBuffer, // synchronous texture upload command buffer
	upload_fence:       vk.Fence,
	frames:             []Frame_Context,
	frame_index:        int,
	active_frame_count: int,
	grid_generation:    u64,
	osd_generation:     u64,
	render_finished:    []vk.Semaphore,
	images_in_flight:   []vk.Fence,
	timestamp_period:   f64,
	timestamp_bits:     u32,
	capture_buffer:     Gpu_Buffer,
	capture_path:       string,
	capture_complete:   bool,
	capture_deadline:   f64,
	capture_exit:       bool,
	framebuffer_readback: bool,
	cursor_gpu_test:    bool,
	framebuffer_dirty:  bool,
	minimized:          bool,
	redraw:             bool,
	focused:            bool,
	cursor_animation:   Cursor_Animation_State,
	scroll_indicator:   Scroll_Indicator_State,
	osd:                Osd_State,
	settings:           Application_Settings,
	applied_settings:   Application_Settings,
	font_catalog:       ^Font_Catalog,
	active_font_index:  int,
	settings_path:      string,
	settings_save_pending: bool,
	settings_save_deadline: f64,
	settings_font_rebuild_pending: bool,
	glyph_cache_reset_pending: bool,
	settings_layout_pending: bool,
	detected_display_rotation: Display_Rotation,
	display_rotation_check_pending: bool,
	display_rotation_check_deadline: f64,
	content_scale_x:    f32,
	content_scale_y:    f32,
	pending_key:        i32,
	pending_scancode:   i32,
	pending_action:     i32,
	pending_mods:       i32,
	pending_valid:      bool,
	font_size_shortcut: Font_Size_Shortcut_State,
	selection:          Terminal_Selection,
	clipboard_insert_suppressed: bool,
	mouse_buttons:      u16,
	pending_paste:      []u8,
	paste_confirmation: bool,
	selection_text_cursor:  glfw.CursorHandle,
	selection_block_cursor: glfw.CursorHandle,
}

benchmark_samples_destroy :: proc(samples: ^Benchmark_Samples) {
	delete(samples.cpu_redraw)
	delete(samples.gpu_draw)
	delete(samples.total)
}

benchmark_add_sample :: proc(samples: ^Benchmark_Samples, sample: Benchmark_Frame_Sample) {
	append(&samples.cpu_redraw, sample.cpu_redraw_ms)
	append(&samples.total, sample.total_ms)
	samples.cell_bytes_uploaded += sample.cell_bytes_uploaded
	samples.visual_bytes_uploaded += sample.visual_bytes_uploaded
	if sample.has_gpu_time {
		append(&samples.gpu_draw, sample.gpu_draw_ms)
	}
}

benchmark_summarize :: proc(values: []f64) -> Benchmark_Summary {
	if len(values) == 0 {
		return {}
	}
	sorted := make([]f64, len(values), context.temp_allocator)
	copy(sorted, values)
	sort.sort(sort.slice_interface(&sorted))

	sum := f64(0)
	for value in sorted {
		sum += value
	}
	return {
		minimum = sorted[0],
		median = sorted[(len(sorted) - 1) / 2],
		p95 = sorted[int(f64(len(sorted) - 1) * 0.95)],
		mean = sum / f64(len(sorted)),
		maximum = sorted[len(sorted) - 1],
	}
}

benchmark_print_series :: proc(label: string, summary: Benchmark_Summary) {
	fmt.printfln(
		"  %s: mean %.3f ms, p50 %.3f, p95 %.3f, min %.3f, max %.3f",
		label,
		summary.mean,
		summary.median,
		summary.p95,
		summary.minimum,
		summary.maximum,
	)
}

benchmark_print :: proc(app: ^Vulkan_App, samples: ^Benchmark_Samples) {
	fmt.printfln(
		"\nRender benchmark: %d measured redraws after %d warmup frames (%dx%d framebuffer)",
		len(samples.total),
		BENCHMARK_WARMUP_FRAMES,
		app.extent.width,
		app.extent.height,
	)
	fmt.printfln("  Present mode: %v", choose_present_mode(query_swapchain_support(app).present_modes))
	benchmark_print_series("CPU prepare/record/submit", benchmark_summarize(samples.cpu_redraw[:]))
	if len(samples.gpu_draw) == len(samples.total) {
		gpu := benchmark_summarize(samples.gpu_draw[:])
		benchmark_print_series("GPU timestamp draw", gpu)
		if gpu.mean > 0 {
			fmt.printfln("  GPU-only throughput estimate: %.0f redraws/s", 1000.0 / gpu.mean)
		}
	} else {
		fmt.println("  GPU timestamp draw: unavailable on this graphics queue")
	}
	benchmark_print_series("Total serialized redraw", benchmark_summarize(samples.total[:]))
	if len(samples.total) > 0 {
		fmt.printfln(
			"  Metadata uploaded per redraw: %.0f cell bytes, %.0f visual bytes",
			f64(samples.cell_bytes_uploaded) / f64(len(samples.total)),
			f64(samples.visual_bytes_uploaded) / f64(len(samples.total)),
		)
	}
	fmt.println(
		"  Total includes presentation and the demo's deliberate per-frame queue wait.",
	)
}

choose_present_mode :: proc(available: []vk.PresentModeKHR) -> vk.PresentModeKHR {
	when BENCHMARK_MODE {
		for mode in available {
			if mode == .IMMEDIATE do return mode
		}
		for mode in available {
			if mode == .MAILBOX do return mode
		}
	}
	return .FIFO
}

app_from_window :: proc(window: glfw.WindowHandle) -> ^Vulkan_App {
	return cast(^Vulkan_App)glfw.GetWindowUserPointer(window)
}

glfw_key_is_printable :: proc(key: i32) -> bool {
	return(
		(key >= glfw.KEY_A && key <= glfw.KEY_Z) ||
		(key >= glfw.KEY_0 && key <= glfw.KEY_9) ||
		key == glfw.KEY_SPACE ||
		(key >= glfw.KEY_APOSTROPHE && key <= glfw.KEY_GRAVE_ACCENT) ||
		key == glfw.KEY_WORLD_1 ||
		key == glfw.KEY_WORLD_2 \
	)
}

glfw_key_modifiers :: proc(app: ^Vulkan_App, mods: i32) -> u16 {
	result := u16(mods & 0x3f)
	if glfw.GetKey(app.window, glfw.KEY_RIGHT_SHIFT) == glfw.PRESS do result |= 1 << 6
	if glfw.GetKey(app.window, glfw.KEY_RIGHT_CONTROL) == glfw.PRESS do result |= 1 << 7
	if glfw.GetKey(app.window, glfw.KEY_RIGHT_ALT) == glfw.PRESS do result |= 1 << 8
	if glfw.GetKey(app.window, glfw.KEY_RIGHT_SUPER) == glfw.PRESS do result |= 1 << 9
	return result
}

unshifted_codepoint_for_key :: proc(key, scancode: i32) -> u32 {
	name := glfw.GetKeyName(key, scancode)
	for codepoint in name do return u32(codepoint)
	return 0
}

send_key_event :: proc(app: ^Vulkan_App, key, scancode, action, mods: i32, text: []u8 = nil) {
	if app.demo.demo_mode || app.demo.session.handle == nil do return
	buffer: [256]u8
	encoded, ok := terminal_core_encode_glfw_key(
		&app.demo.terminal,
		key,
		action,
		glfw_key_modifiers(app, mods),
		text,
		unshifted_codepoint_for_key(key, scancode),
		buffer[:],
	)
	if ok && len(encoded) > 0 {
		selection_clear(&app.selection)
		if terminal_input_returns_to_tail(
			action,
			ok,
			len(encoded),
			app.demo.snapshot.viewport_active,
		) {
			previous_offset := app.demo.snapshot.scroll_offset_rows
			terminal_core_scroll_bottom(&app.demo.terminal)
			_ = refresh_terminal_display(app)
			if app.demo.snapshot.viewport_active ||
			   app.demo.snapshot.scroll_offset_rows != previous_offset {
				 scroll_indicator_reveal(&app.scroll_indicator, glfw.GetTime())
			}
		}
		_ = terminal_session_write(&app.demo.session, encoded)
		app.redraw = true
	}
}

selection_snapshot_updated :: proc(app: ^Vulkan_App) {
	if app == nil || app.demo == nil do return
	if !selection_sync_tracked_endpoints(&app.selection) ||
	   selection_should_clear_for_snapshot(&app.selection, &app.demo.snapshot) {
		selection_clear(&app.selection)
	} else if app.selection.active {
		_ = selection_rebuild_mask(&app.selection, &app.demo.snapshot)
	}
	app.redraw = true
}

selection_copy_to_clipboard :: proc(app: ^Vulkan_App) -> bool {
	if app == nil || !app.selection.active || app.demo.terminal.handle == nil do return false
	trim := app.settings.block_selection_whitespace == .Trim
	text, ok := terminal_core_selection_text(
		&app.demo.terminal,
		app.selection.anchor.x,
		app.selection.anchor.y,
		app.selection.focus.x,
		app.selection.focus.y,
		app.selection.mode == .Rectangle,
		trim,
	)
	if !ok || len(text) == 0 {
		delete(text)
		return false
	}
	delete(app.selection.selected_text)
	app.selection.selected_text = make([]u8, len(text))
	copy(app.selection.selected_text, text)
	delete(text)
	c_text, c_error := strings.clone_to_cstring(
		transmute(string)app.selection.selected_text,
		context.temp_allocator,
	)
	if c_error != nil do return false
	glfw.SetClipboardString(app.window, c_text)
	return true
}

clipboard_text :: proc(app: ^Vulkan_App) -> []u8 {
	if app == nil || app.window == nil do return nil
	value := glfw.GetClipboardString(app.window)
	if value == "" do return nil
	return transmute([]u8)value
}

paste_line_count :: proc(data: []u8) -> int {
	if len(data) == 0 do return 0
	count := 1
	for byte in data do if byte == '\n' do count += 1
	return count
}

paste_commit :: proc(app: ^Vulkan_App, data: []u8) -> bool {
	if app == nil || len(data) == 0 || app.demo.session.handle == nil do return false
	encoded, ok := terminal_core_encode_paste(&app.demo.terminal, data, context.temp_allocator)
	if !ok || len(encoded) == 0 do return false
	if !app.demo.snapshot.viewport_active {
		previous_offset := app.demo.snapshot.scroll_offset_rows
		terminal_core_scroll_bottom(&app.demo.terminal)
		_ = refresh_terminal_display(app)
		selection_snapshot_updated(app)
		if app.demo.snapshot.scroll_offset_rows != previous_offset {
			scroll_indicator_reveal(&app.scroll_indicator, glfw.GetTime())
		}
	}
	selection_clear(&app.selection)
	_ = terminal_session_write(&app.demo.session, encoded)
	app.redraw = true
	return true
}

paste_request :: proc(app: ^Vulkan_App, data: []u8) -> bool {
	if app == nil || len(data) == 0 do return false
	if app.settings.paste_protection && !terminal_paste_is_safe(data) {
		delete(app.pending_paste)
		app.pending_paste = make([]u8, len(data))
		copy(app.pending_paste, data)
		app.paste_confirmation = true
		app.osd.page = .Paste_Confirm
		app.osd.paste_bytes = len(data)
		app.osd.paste_lines = paste_line_count(data)
		app.osd.visible = true
		osd_prepare(app)
		app.redraw = true
		return true
	}
	return paste_commit(app, data)
}

paste_from_clipboard :: proc(app: ^Vulkan_App) -> bool {
	return paste_request(app, clipboard_text(app))
}

process_terminal_clipboard :: proc(app: ^Vulkan_App) {
	if app == nil || app.demo == nil || app.demo.terminal.handle == nil do return
	for _ in 0 ..< 4 {
		event_type, data, ok := terminal_core_clipboard_poll(
			&app.demo.terminal,
			context.temp_allocator,
		)
		if !ok || event_type == .None do return
		switch event_type {
		case .None:
			return
		case .Write:
			if app.settings.terminal_clipboard != .Blocked {
				c_text, c_error := strings.clone_to_cstring(
					transmute(string)data,
					context.temp_allocator,
				)
				if c_error == nil do glfw.SetClipboardString(app.window, c_text)
			}
		case .Read:
			if app.settings.terminal_clipboard == .Read_Write {
				_ = terminal_core_clipboard_respond(&app.demo.terminal, clipboard_text(app))
			}
		}
	}
}

clipboard_insert_key_event :: proc(
	app: ^Vulkan_App,
	key, action, mods: i32,
) -> bool {
	if key != glfw.KEY_INSERT {
		return false
	}
	if app.clipboard_insert_suppressed {
		if action == glfw.RELEASE do app.clipboard_insert_suppressed = false
		return true
	}
	if !app.settings.clipboard_insert_shortcuts do return false
	semantic := mods & (glfw.MOD_SHIFT | glfw.MOD_CONTROL | glfw.MOD_ALT | glfw.MOD_SUPER)
	copy_key := semantic == glfw.MOD_CONTROL
	paste_key := semantic == glfw.MOD_SHIFT
	if !copy_key && !paste_key do return false
	app.clipboard_insert_suppressed = true
	if action == glfw.PRESS {
		if copy_key {
			_ = selection_copy_to_clipboard(app)
		} else {
			_ = paste_from_clipboard(app)
		}
	}
	if action == glfw.RELEASE do app.clipboard_insert_suppressed = false
	return true
}

scroll_terminal_rows :: proc(app: ^Vulkan_App, delta: i64) {
	if app.demo == nil || app.demo.terminal.handle == nil || delta == 0 do return
	previous_offset := app.demo.snapshot.scroll_offset_rows
	previous_active := app.demo.snapshot.viewport_active
	terminal_core_scroll_rows(&app.demo.terminal, delta)
	_ = refresh_terminal_display(app)
	selection_snapshot_updated(app)
	if app.demo.snapshot.scroll_offset_rows != previous_offset ||
	   app.demo.snapshot.viewport_active != previous_active {
		scroll_indicator_reveal(&app.scroll_indicator, glfw.GetTime())
		app.redraw = true
	}
}

adjust_font_size_from_shortcut :: proc(app: ^Vulkan_App, delta: int) {
	if app == nil || delta == 0 do return
	adjusted, changed := font_size_shortcut_adjust(app.settings.font_size, delta)
	if changed {
		app.settings.font_size = adjusted
		settings_changed(app, {.Font_Resources, .Layout})
	}
}

flush_pending_key :: proc(app: ^Vulkan_App) {
	if !app.pending_valid do return
	name := glfw.GetKeyName(app.pending_key, app.pending_scancode)
	send_key_event(
		app,
		app.pending_key,
		app.pending_scancode,
		app.pending_action,
		app.pending_mods,
		transmute([]u8)name,
	)
	app.pending_valid = false
}

key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: c.int) {
	context = runtime.default_context()
	app := app_from_window(window)
	if app == nil do return
	defer selection_update_mouse_cursor(app)
	if app.paste_confirmation {
		app.pending_valid = false
		if action == glfw.PRESS && key == glfw.KEY_ENTER {
			pending := app.pending_paste
			app.pending_paste = nil
			app.paste_confirmation = false
			app.osd.visible = false
			app.osd.page = .Main
			_ = paste_commit(app, pending)
			delete(pending)
			settings_flush(app)
		} else if action == glfw.PRESS && key == glfw.KEY_ESCAPE {
			delete(app.pending_paste)
			app.pending_paste = nil
			app.paste_confirmation = false
			app.osd.visible = false
			app.osd.page = .Main
			app.redraw = true
		}
		return
	}
	ctrl_comma := key == glfw.KEY_COMMA && mods & glfw.MOD_CONTROL != 0
	if ctrl_comma || (key == glfw.KEY_COMMA && app.osd.comma_suppressed) {
		app.pending_valid = false
		if action == glfw.PRESS {
			app.osd.comma_suppressed = true
			osd_set_visible(app, !app.osd.visible)
		} else if action == glfw.RELEASE {
			app.osd.comma_suppressed = false
		}
		return
	}
	if app.osd.visible {
		app.pending_valid = false
		if action == glfw.PRESS || action == glfw.REPEAT do osd_handle_key(app, i32(key), i32(mods))
		return
	}
	if clipboard_insert_key_event(app, i32(key), i32(action), i32(mods)) {
		app.pending_valid = false
		return
	}
	font_delta, font_handled := font_size_shortcut_event(
		&app.font_size_shortcut,
		i32(key),
		i32(action),
		i32(mods),
		app.settings.font_size_shortcuts,
	)
	if font_handled {
		flush_pending_key(app)
		if font_delta != 0 do adjust_font_size_from_shortcut(app, font_delta)
		return
	}
	flush_pending_key(app)
	scroll_delta, scroll_handled := scroll_delta_for_key(
		i32(key),
		i32(action),
		i32(mods),
		app.demo.snapshot.rows,
		app.demo.snapshot.scroll_total_rows,
		app.settings.scroll_page_modifier,
		app.settings.scroll_line_modifier,
	)
	if scroll_handled {
		if scroll_delta != 0 do scroll_terminal_rows(app, scroll_delta)
		return
	}
	printable := glfw_key_is_printable(i32(key))
	if printable && action != glfw.RELEASE {
		app.pending_key = i32(key)
		app.pending_scancode = i32(scancode)
		app.pending_action = i32(action)
		app.pending_mods = i32(mods)
		app.pending_valid = true
		return
	}
	send_key_event(app, i32(key), i32(scancode), i32(action), i32(mods))
}

char_callback :: proc "c" (window: glfw.WindowHandle, codepoint: rune) {
	context = runtime.default_context()
	app := app_from_window(window)
	if app == nil do return
	if app.paste_confirmation || app.osd.visible || app.osd.comma_suppressed ||
	   app.clipboard_insert_suppressed ||
	   font_size_shortcut_suppresses_character(&app.font_size_shortcut) {
		app.pending_valid = false
		if app.osd.visible do osd_handle_character(app, codepoint)
		return
	}
	bytes, count := utf8.encode_rune(codepoint)
	if app.pending_valid {
		send_key_event(
			app,
			app.pending_key,
			app.pending_scancode,
			app.pending_action,
			app.pending_mods,
			bytes[:count],
		)
		app.pending_valid = false
	} else {
		send_key_event(app, glfw.KEY_UNKNOWN, 0, glfw.PRESS, 0, bytes[:count])
	}
}

current_mouse_modifiers :: proc(app: ^Vulkan_App) -> i32 {
	mods: i32
	if glfw.GetKey(app.window, glfw.KEY_LEFT_SHIFT) == glfw.PRESS ||
	   glfw.GetKey(app.window, glfw.KEY_RIGHT_SHIFT) == glfw.PRESS {
		mods |= glfw.MOD_SHIFT
	}
	if glfw.GetKey(app.window, glfw.KEY_LEFT_CONTROL) == glfw.PRESS ||
	   glfw.GetKey(app.window, glfw.KEY_RIGHT_CONTROL) == glfw.PRESS {
		mods |= glfw.MOD_CONTROL
	}
	if glfw.GetKey(app.window, glfw.KEY_LEFT_ALT) == glfw.PRESS ||
	   glfw.GetKey(app.window, glfw.KEY_RIGHT_ALT) == glfw.PRESS {
		mods |= glfw.MOD_ALT
	}
	if glfw.GetKey(app.window, glfw.KEY_LEFT_SUPER) == glfw.PRESS ||
	   glfw.GetKey(app.window, glfw.KEY_RIGHT_SUPER) == glfw.PRESS {
		mods |= glfw.MOD_SUPER
	}
	return mods
}

selection_update_mouse_cursor :: proc(app: ^Vulkan_App) {
	if app == nil || app.window == nil do return
	if app.paste_confirmation || app.osd.visible {
		glfw.SetCursor(app.window, nil)
		return
	}
	mouse_tracking := terminal_core_mouse_tracking(&app.demo.terminal)
	mods := current_mouse_modifiers(app)
	override := !mouse_tracking || mods & glfw.MOD_SHIFT != 0
	if !override {
		glfw.SetCursor(app.window, nil)
		return
	}
	if selection_modifiers_rectangle(mods, mouse_tracking) {
		glfw.SetCursor(app.window, app.selection_block_cursor)
	} else {
		glfw.SetCursor(app.window, app.selection_text_cursor)
	}
}

terminal_mouse_button :: proc(button: i32) -> Terminal_Mouse_Button {
	switch button {
	case glfw.MOUSE_BUTTON_LEFT: return .Left
	case glfw.MOUSE_BUTTON_RIGHT: return .Right
	case glfw.MOUSE_BUTTON_MIDDLE: return .Middle
	}
	return .None
}

send_mouse_event :: proc(
	app: ^Vulkan_App,
	action: Terminal_Mouse_Action,
	button: Terminal_Mouse_Button,
	mods: i32,
	x, y: f64,
) {
	if app == nil || app.demo.session.handle == nil do return
	area := text_render_area(app)
	metrics := app.demo.resources.cell_metrics
	fx, fy := mouse_framebuffer_position(app, x, y)
	buffer: [128]u8
	encoded, ok := terminal_core_encode_mouse(
		&app.demo.terminal,
		action,
		button,
		glfw_key_modifiers(app, mods),
		f32(fx),
		f32(fy),
		app.extent.width,
		app.extent.height,
		metrics.cell_width,
		metrics.cell_height,
		u32(max(area.offset.y, 0)),
		u32(max(i32(app.extent.height) - area.offset.y - i32(area.extent.height), 0)),
		u32(max(i32(app.extent.width) - area.offset.x - i32(area.extent.width), 0)),
		u32(max(area.offset.x, 0)),
		app.mouse_buttons != 0,
		buffer[:],
	)
	if ok && len(encoded) > 0 {
		_ = terminal_session_write(&app.demo.session, encoded)
	}
}

mouse_framebuffer_position :: proc(app: ^Vulkan_App, x, y: f64) -> (f64, f64) {
	window_width, window_height := glfw.GetWindowSize(app.window)
	framebuffer_width, framebuffer_height := glfw.GetFramebufferSize(app.window)
	scale_x, scale_y := framebuffer_coordinate_scale(
		i32(window_width),
		i32(window_height),
		i32(framebuffer_width),
		i32(framebuffer_height),
	)
	return x * scale_x, y * scale_y
}

mouse_selection_point :: proc(app: ^Vulkan_App, x, y: f64) -> Selection_Point {
	area := text_render_area(app)
	metrics := app.demo.resources.cell_metrics
	framebuffer_x, framebuffer_y := mouse_framebuffer_position(app, x, y)
	return selection_screen_point_from_pixel(
		&app.demo.snapshot,
		area.offset.x,
		area.offset.y,
		i32(area.extent.width),
		i32(area.extent.height),
		metrics.cell_width,
		metrics.cell_height,
		framebuffer_x,
		framebuffer_y,
	)
}

selection_set_autoscroll :: proc(app: ^Vulkan_App, framebuffer_y: f64) {
	area := text_render_area(app)
	metrics := app.demo.resources.cell_metrics
	delta := i64(0)
	if framebuffer_y < f64(area.offset.y) {
		distance := f64(area.offset.y) - framebuffer_y
		delta = -i64(max(1, int(distance / f64(metrics.cell_height)) + 1))
	} else if framebuffer_y >= f64(area.offset.y + i32(area.extent.height)) {
		distance := framebuffer_y - f64(area.offset.y + i32(area.extent.height))
		delta = i64(max(1, int(distance / f64(metrics.cell_height)) + 1))
	}
	app.selection.autoscroll_rows = clamp(delta, -i64(app.demo.snapshot.rows), i64(app.demo.snapshot.rows))
	if delta != 0 && app.selection.autoscroll_next_at == max(f64) {
		app.selection.autoscroll_next_at = glfw.GetTime()
	}
}

mouse_button_callback :: proc "c" (window: glfw.WindowHandle, button, action, mods: c.int) {
	context = runtime.default_context()
	app := app_from_window(window)
	if app == nil do return
	if app.osd.visible || app.paste_confirmation do return
	mouse_tracking := terminal_core_mouse_tracking(&app.demo.terminal)
	if button >= 0 && button < 16 {
		bit := u16(1) << u16(button)
		if action == glfw.PRESS {
			app.mouse_buttons |= bit
		} else if action == glfw.RELEASE {
			app.mouse_buttons &~= bit
		}
	}
	override := !mouse_tracking || mods & glfw.MOD_SHIFT != 0
	x, y := glfw.GetCursorPos(window)

	if button == glfw.MOUSE_BUTTON_RIGHT && override {
		if app.settings.right_click_paste && action == glfw.PRESS {
			_ = paste_from_clipboard(app)
		}
		return
	}
	if button == glfw.MOUSE_BUTTON_LEFT && override {
		point := mouse_selection_point(app, x, y)
		if action == glfw.PRESS {
			mode := Selection_Mode.Linear
			if selection_modifiers_rectangle(i32(mods), mouse_tracking) do mode = .Rectangle
			selection_begin(&app.selection, &app.demo.terminal, &app.demo.snapshot, point, mode, x, y, glfw.GetTime())
			app.redraw = true
		} else if action == glfw.RELEASE && app.selection.dragging {
			selection_extend(&app.selection, &app.demo.terminal, &app.demo.snapshot, point, x, y)
			selection_release(&app.selection)
			if app.settings.copy_on_select do _ = selection_copy_to_clipboard(app)
			app.redraw = true
		}
		selection_update_mouse_cursor(app)
		return
	}
	if mouse_tracking {
		mouse_action := Terminal_Mouse_Action.Press
		if action == glfw.RELEASE do mouse_action = .Release
		send_mouse_event(app, mouse_action, terminal_mouse_button(i32(button)), i32(mods), x, y)
	}
}

cursor_position_callback :: proc "c" (window: glfw.WindowHandle, x, y: f64) {
	context = runtime.default_context()
	app := app_from_window(window)
	if app == nil do return
	selection_update_mouse_cursor(app)
	if app.paste_confirmation || app.osd.visible do return
	mouse_tracking := terminal_core_mouse_tracking(&app.demo.terminal)
	mods := current_mouse_modifiers(app)
	override := !mouse_tracking || mods & glfw.MOD_SHIFT != 0
	if app.selection.dragging && override {
		point := mouse_selection_point(app, x, y)
		selection_extend(&app.selection, &app.demo.terminal, &app.demo.snapshot, point, x, y)
		if app.selection.drag_threshold_passed {
			_, framebuffer_y := mouse_framebuffer_position(app, x, y)
			selection_set_autoscroll(app, framebuffer_y)
		}
		app.redraw = true
	} else if mouse_tracking && !override {
		send_mouse_event(app, .Motion, .None, mods, x, y)
	}
}

scroll_callback :: proc "c" (window: glfw.WindowHandle, xoffset, yoffset: f64) {
	context = runtime.default_context()
	app := app_from_window(window)
	if app == nil || app.osd.visible || app.paste_confirmation do return
	mouse_tracking := terminal_core_mouse_tracking(&app.demo.terminal)
	mods := current_mouse_modifiers(app)
	if !mouse_tracking || mods & glfw.MOD_SHIFT != 0 do return
	x, y := glfw.GetCursorPos(window)
	button := Terminal_Mouse_Button.Four
	if yoffset < 0 do button = .Five
	steps := max(1, int(abs(yoffset)))
	for _ in 0 ..< steps {
		send_mouse_event(app, .Press, button, mods, x, y)
	}
}

framebuffer_size_callback :: proc "c" (window: glfw.WindowHandle, width, height: c.int) {
	context = runtime.default_context()
	app := app_from_window(window)
	if app == nil do return
	app.minimized = width <= 0 || height <= 0
	app.framebuffer_dirty = !app.minimized
	if !app.cursor_gpu_test {
		app.display_rotation_check_pending = true
		app.display_rotation_check_deadline = glfw.GetTime() + 0.15
	}
	if !app.minimized do osd_prepare(app)
	app.redraw = true
}

window_refresh_callback :: proc "c" (window: glfw.WindowHandle) {
	context = runtime.default_context()
	app := app_from_window(window)
	if app != nil do app.redraw = true
}

window_position_callback :: proc "c" (window: glfw.WindowHandle, x, y: c.int) {
	context = runtime.default_context()
	app := app_from_window(window)
	if app == nil || app.cursor_gpu_test do return
	app.display_rotation_check_pending = true
	app.display_rotation_check_deadline = glfw.GetTime() + 0.15
}

window_focus_callback :: proc "c" (window: glfw.WindowHandle, focused: c.int) {
	context = runtime.default_context()
	app := app_from_window(window)
	if app == nil do return
	app.focused = focused != 0
	if !app.focused {
		font_size_shortcut_clear(&app.font_size_shortcut)
	}
	selection_update_mouse_cursor(app)
	app.redraw = true
}

window_content_scale_callback :: proc "c" (
	window: glfw.WindowHandle,
	xscale, yscale: f32,
) {
	context = runtime.default_context()
	app := app_from_window(window)
	if app == nil || (app.content_scale_x == xscale && app.content_scale_y == yscale) do return
	app.content_scale_x = max(xscale, f32(1))
	app.content_scale_y = max(yscale, f32(1))
	if !app.cursor_gpu_test {
		app.display_rotation_check_pending = true
		app.display_rotation_check_deadline = glfw.GetTime() + 0.15
	}
	app.settings_font_rebuild_pending = true
	app.settings_layout_pending = true
	app.redraw = true
}

cursor_animation_input :: proc(app: ^Vulkan_App) -> Cursor_Animation_Input {
	return {
		visible = app.demo.snapshot.cursor_visible,
		blinking = app.demo.snapshot.cursor_blinking,
		text_blinking = display_grid_has_blinking_text(&app.demo.grid),
		focused = app.focused,
		minimized = app.minimized,
	}
}

sample_cursor_animation :: proc(app: ^Vulkan_App, now: f64) -> Cursor_Animation_Sample {
	return cursor_animation_sample(
		app.settings.cursor_animation,
		cursor_animation_input(app),
		app.cursor_animation.epoch,
		now,
	)
}

reset_cursor_animation :: proc(app: ^Vulkan_App, now: f64) {
	_ = cursor_animation_restart(
		&app.cursor_animation,
		app.settings.cursor_animation,
		cursor_animation_input(app),
		now,
	)
	app.redraw = true
}

settings_flush :: proc(app: ^Vulkan_App) {
	if !app.settings_save_pending || app.settings_path == "" do return
	if settings_save(app.settings_path, app.settings) {
		app.settings_save_pending = false
	} else {
		fmt.eprintfln("Grimalkin could not save settings to %s", app.settings_path)
	}
}

window_outer_geometry :: proc(window: glfw.WindowHandle) -> [4]i32 {
	x, y := glfw.GetWindowPos(window)
	width, height := glfw.GetWindowSize(window)
	left, top, right, bottom := glfw.GetWindowFrameSize(window)
	return {
		x - left,
		y - top,
		width + left + right,
		height + top + bottom,
	}
}

apply_window_style :: proc(app: ^Vulkan_App) {
	if app.window == nil do return
	frameless := app.settings.window_style == .Frameless
	outer := window_outer_geometry(app.window)
	maximized := glfw.GetWindowAttrib(app.window, glfw.MAXIMIZED) != 0
	glfw.SetWindowAttrib(app.window, glfw.DECORATED, frameless ? glfw.FALSE : glfw.TRUE)
	when ODIN_OS == .Darwin {
		if grimalkin_macos_configure_window(rawptr(app.window), frameless ? 1 : 0) == 0 {
			fmt.eprintln("macOS could not apply native window behavior")
		}
	}
	// Keep the complete window inside its previous footprint. This deliberately
	// changes the client extent so adding a frame cannot grow beyond a monitor
	// edge and removing one continues to fill a snapped or zoned rectangle.
	if !maximized && outer[2] > 0 && outer[3] > 0 {
		left, top, right, bottom := glfw.GetWindowFrameSize(app.window)
		width := max(1, outer[2] - left - right)
		height := max(1, outer[3] - top - bottom)
		glfw.SetWindowSize(app.window, width, height)
		glfw.SetWindowPos(app.window, outer[0] + left, outer[1] + top)
	}
	app.redraw = true
}

settings_changed :: proc(app: ^Vulkan_App, change: Osd_Settings_Change) {
	if change == {} do return
	app.settings_save_pending = true
	app.settings_save_deadline = glfw.GetTime() + 0.4
	if .Font_Resources in change do app.settings_font_rebuild_pending = true
	if .Font_Resources not_in change do app.applied_settings = app.settings
	if .Layout in change do app.settings_layout_pending = true
	if .Cursor in change do reset_cursor_animation(app, glfw.GetTime())
	if .Window_Style in change do apply_window_style(app)
	osd_prepare(app)
	app.redraw = true
}

osd_prepare :: proc(app: ^Vulkan_App) {
	if app.demo == nil || app.extent.width == 0 || app.extent.height == 0 do return
	if app.osd.page == .Main && !osd_main_row_enabled(app.settings, app.osd.selected) {
		app.osd.selected = osd_move_main_selection(app.settings, app.osd.selected, 1)
	}
	if app.osd.page == .Font && !osd_font_row_enabled(app.font_catalog, app.osd.selected) {
		app.osd.selected = osd_move_font_selection(app.font_catalog, app.osd.selected, 1)
	}
	metrics := app.demo.resources.cell_metrics
	cols, rows := osd_layout_dimensions(
		app.extent.width,
		app.extent.height,
		metrics.cell_width,
		metrics.cell_height,
		app.osd.page,
	)
	osd_resize(&app.osd, cols, rows)
	osd_rebuild(
		&app.osd,
		&app.demo.resources,
		app.settings,
		app.font_catalog,
		app.detected_display_rotation,
	)
}

osd_set_visible :: proc(app: ^Vulkan_App, visible: bool) {
	if visible {
		font_size_shortcut_clear(&app.font_size_shortcut)
		if app.osd.page == .Text_Rendering do app.osd.selected = OSD_TEXT_RENDERING_ROW
		if app.osd.page == .Font || app.osd.page == .Font_List do app.osd.selected = OSD_FONT_ROW
		if app.osd.page == .Key_Bindings do app.osd.selected = OSD_KEY_BINDING_ROW
		if app.osd.page == .Copy_Paste do app.osd.selected = OSD_COPY_PASTE_ROW
		app.osd.page = .Main
		app.osd.selected = clamp(app.osd.selected, 0, OSD_MAIN_ROW_COUNT - 1)
	}
	app.osd.visible = visible
	if visible {
		osd_prepare(app)
	} else {
		settings_flush(app)
	}
	app.redraw = true
}

osd_handle_key :: proc(app: ^Vulkan_App, key, mods: i32) {
	change := Osd_Settings_Change{}
	if mods & glfw.MOD_SHIFT != 0 && key == glfw.KEY_R {
		app.settings = application_settings_default()
		change = {.Font_Resources, .Layout, .Cursor, .Window_Style, .Input}
		settings_changed(app, change)
		return
	}
	if app.osd.page == .Text_Rendering {
		switch key {
		case glfw.KEY_ESCAPE:
			app.osd.page = .Main
			app.osd.selected = OSD_TEXT_RENDERING_ROW
		case glfw.KEY_UP:
			app.osd.selected = osd_move_text_rendering_selection(
				app.settings,
				app.osd.selected,
				-1,
				app.detected_display_rotation,
			)
		case glfw.KEY_DOWN:
			app.osd.selected = osd_move_text_rendering_selection(
				app.settings,
				app.osd.selected,
				1,
				app.detected_display_rotation,
			)
		case glfw.KEY_LEFT:
			change = osd_adjust_text_rendering(
				&app.settings,
				app.osd.selected,
				-1,
				app.detected_display_rotation,
			)
		case glfw.KEY_RIGHT:
			change = osd_adjust_text_rendering(
				&app.settings,
				app.osd.selected,
				1,
				app.detected_display_rotation,
			)
		case glfw.KEY_R:
			change = osd_reset_text_rendering(
				&app.settings,
				app.osd.selected,
				app.detected_display_rotation,
			)
		}
		settings_changed(app, change)
		if change == {} do osd_prepare(app)
		app.redraw = true
		return
	}
	if app.osd.page == .Font_List {
		count := osd_font_list_count(app.font_catalog)
		visible := osd_font_list_visible_rows(&app.osd)
		switch key {
		case glfw.KEY_ESCAPE:
			if app.osd.font_search != "" {
				delete(app.osd.font_search)
				app.osd.font_search = ""
			}
			app.osd.page = .Font
			app.osd.selected = 0
		case glfw.KEY_UP:
			app.osd.font_list_candidate = max(0, app.osd.font_list_candidate - 1)
		case glfw.KEY_DOWN:
			app.osd.font_list_candidate = min(count - 1, app.osd.font_list_candidate + 1)
		case glfw.KEY_PAGE_UP:
			app.osd.font_list_candidate = max(0, app.osd.font_list_candidate - visible)
		case glfw.KEY_PAGE_DOWN:
			app.osd.font_list_candidate = min(count - 1, app.osd.font_list_candidate + visible)
		case glfw.KEY_HOME:
			app.osd.font_list_candidate = 0
		case glfw.KEY_END:
			app.osd.font_list_candidate = count - 1
		case glfw.KEY_BACKSPACE:
			if app.osd.font_search != "" {
				end := len(app.osd.font_search) - 1
				for end > 0 && (u8(app.osd.font_search[end]) & 0xc0) == 0x80 do end -= 1
				replacement := strings.clone(app.osd.font_search[:end])
				delete(app.osd.font_search)
				app.osd.font_search = replacement
				app.osd.font_search_deadline = glfw.GetTime() + 1.25
				osd_font_search_next(&app.osd, app.font_catalog)
			}
		case glfw.KEY_ENTER:
			if app.osd.font_list_candidate == 0 {
				app.settings.font_family = font_family_setting_auto()
			} else {
				index := app.osd.font_list_candidate - 1
				if index >= 0 && index < len(app.font_catalog.families) {
					app.settings.font_family, _ = font_family_setting_make(
						app.font_catalog.families[index].name,
					)
				}
			}
			delete(app.osd.font_error)
			app.osd.font_error = ""
			app.osd.page = .Font
			app.osd.selected = 0
			change = {.Font_Resources, .Layout}
		}
		osd_font_list_clamp_top(&app.osd, app.font_catalog)
		settings_changed(app, change)
		if change == {} do osd_prepare(app)
		app.redraw = true
		return
	}
	if app.osd.page == .Font {
		switch key {
		case glfw.KEY_ESCAPE:
			app.osd.page = .Main
			app.osd.selected = OSD_FONT_ROW
		case glfw.KEY_UP:
			app.osd.selected = osd_move_font_selection(app.font_catalog, app.osd.selected, -1)
		case glfw.KEY_DOWN:
			app.osd.selected = osd_move_font_selection(app.font_catalog, app.osd.selected, 1)
		case glfw.KEY_LEFT:
			change = osd_adjust_font_setting(&app.settings, app.osd.selected, -1)
		case glfw.KEY_RIGHT, glfw.KEY_ENTER, glfw.KEY_SPACE:
			if app.osd.selected == 0 && osd_font_row_enabled(app.font_catalog, 0) {
				app.osd.page = .Font_List
				app.osd.font_list_candidate = osd_font_applied_list_index(app.settings, app.font_catalog)
				app.osd.font_list_top = 0
				delete(app.osd.font_error)
				app.osd.font_error = ""
			} else if key == glfw.KEY_RIGHT {
				change = osd_adjust_font_setting(&app.settings, app.osd.selected, 1)
			}
		case glfw.KEY_R:
			change = osd_reset_font_setting(&app.settings, app.osd.selected)
		}
		settings_changed(app, change)
		if change == {} do osd_prepare(app)
		app.redraw = true
		return
	}
	if app.osd.page == .Key_Bindings {
		switch key {
		case glfw.KEY_ESCAPE:
			app.osd.page = .Main
			app.osd.selected = OSD_KEY_BINDING_ROW
		case glfw.KEY_UP:
			app.osd.selected =
				(app.osd.selected + OSD_KEY_BINDING_COUNT - 1) % OSD_KEY_BINDING_COUNT
		case glfw.KEY_DOWN:
			app.osd.selected = (app.osd.selected + 1) % OSD_KEY_BINDING_COUNT
		case glfw.KEY_LEFT:
			change = osd_adjust_key_binding(&app.settings, app.osd.selected, -1)
		case glfw.KEY_RIGHT:
			change = osd_adjust_key_binding(&app.settings, app.osd.selected, 1)
		case glfw.KEY_R:
			change = osd_reset_key_binding(&app.settings, app.osd.selected)
		}
		settings_changed(app, change)
		if change == {} do osd_prepare(app)
		app.redraw = true
		return
	}
	if app.osd.page == .Copy_Paste {
		switch key {
		case glfw.KEY_ESCAPE:
			app.osd.page = .Main
			app.osd.selected = OSD_COPY_PASTE_ROW
		case glfw.KEY_UP:
			app.osd.selected =
				(app.osd.selected + OSD_COPY_PASTE_COUNT - 1) % OSD_COPY_PASTE_COUNT
		case glfw.KEY_DOWN:
			app.osd.selected = (app.osd.selected + 1) % OSD_COPY_PASTE_COUNT
		case glfw.KEY_LEFT:
			change = osd_adjust_copy_paste(&app.settings, app.osd.selected, -1)
		case glfw.KEY_RIGHT:
			change = osd_adjust_copy_paste(&app.settings, app.osd.selected, 1)
		case glfw.KEY_R:
			change = osd_reset_copy_paste(&app.settings, app.osd.selected)
		}
		settings_changed(app, change)
		if change == {} do osd_prepare(app)
		app.redraw = true
		return
	}
	switch key {
	case glfw.KEY_ESCAPE:
		osd_set_visible(app, false)
		return
	case glfw.KEY_UP:
		app.osd.selected = osd_move_main_selection(app.settings, app.osd.selected, -1)
	case glfw.KEY_DOWN:
		app.osd.selected = osd_move_main_selection(app.settings, app.osd.selected, 1)
	case glfw.KEY_LEFT:
		if app.osd.selected != OSD_TEXT_RENDERING_ROW &&
		   app.osd.selected != OSD_FONT_ROW &&
		   app.osd.selected != OSD_KEY_BINDING_ROW &&
		   app.osd.selected != OSD_COPY_PASTE_ROW {
			change = osd_adjust_setting(&app.settings, app.osd.selected, -1)
		}
	case glfw.KEY_RIGHT:
		if app.osd.selected == OSD_TEXT_RENDERING_ROW {
			app.osd.page = .Text_Rendering
			app.osd.selected = 0
		} else if app.osd.selected == OSD_FONT_ROW {
			app.osd.page = .Font
			app.osd.selected = osd_font_row_enabled(app.font_catalog, 0) ? 0 : 1
		} else if app.osd.selected == OSD_KEY_BINDING_ROW {
			app.osd.page = .Key_Bindings
			app.osd.selected = 0
		} else if app.osd.selected == OSD_COPY_PASTE_ROW {
			app.osd.page = .Copy_Paste
			app.osd.selected = 0
		} else {
			change = osd_adjust_setting(&app.settings, app.osd.selected, 1)
		}
	case glfw.KEY_ENTER, glfw.KEY_SPACE:
		if app.osd.selected == OSD_TEXT_RENDERING_ROW {
			app.osd.page = .Text_Rendering
			app.osd.selected = 0
		} else if app.osd.selected == OSD_FONT_ROW {
			app.osd.page = .Font
			app.osd.selected = osd_font_row_enabled(app.font_catalog, 0) ? 0 : 1
		} else if app.osd.selected == OSD_KEY_BINDING_ROW {
			app.osd.page = .Key_Bindings
			app.osd.selected = 0
		} else if app.osd.selected == OSD_COPY_PASTE_ROW {
			app.osd.page = .Copy_Paste
			app.osd.selected = 0
		}
	case glfw.KEY_R:
		change = osd_reset_setting(
			&app.settings,
			app.osd.selected,
			app.detected_display_rotation,
		)
	}
	settings_changed(app, change)
	if change == {} do osd_prepare(app)
	app.redraw = true
}

osd_handle_character :: proc(app: ^Vulkan_App, codepoint: rune) {
	if app == nil || !app.osd.visible || app.osd.page != .Font_List do return
	if codepoint < 0x20 || codepoint == 0x7f do return
	now := glfw.GetTime()
	if app.osd.font_search != "" && now >= app.osd.font_search_deadline {
		delete(app.osd.font_search)
		app.osd.font_search = ""
	}
	bytes, count := utf8.encode_rune(codepoint)
	replacement := strings.concatenate(
		[]string{app.osd.font_search, string(bytes[:count])},
		context.allocator,
	)
	if app.osd.font_search != "" do delete(app.osd.font_search)
	app.osd.font_search = replacement
	app.osd.font_search_deadline = now + 1.25
	osd_font_search_next(&app.osd, app.font_catalog)
	osd_prepare(app)
	app.redraw = true
}

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

refresh_display_rotation :: proc(app: ^Vulkan_App) {
	detected := detect_display_rotation(app.window)
	if detected == app.detected_display_rotation do return
	before := application_settings_render_config(app.settings, app.detected_display_rotation)
	after := application_settings_render_config(app.settings, detected)
	app.detected_display_rotation = detected
	if before != after do app.settings_font_rebuild_pending = true
	osd_prepare(app)
	app.redraw = true
}

run_grimalkin :: proc(mode: Grimalkin_Run_Mode) {
	demo_mode := mode == .Demo
	cursor_gpu_test := mode == .Cursor_Gpu_Test
	if !glfw.Init() {
		description, code := glfw.GetError()
		fmt.panicf("GLFW initialization failed (%d): %s", code, description)
	}
	defer glfw.Terminate()
	xscale, yscale := glfw.GetMonitorContentScale(glfw.GetPrimaryMonitor())
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
		if !started do return
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
	demo := grimalkin_demo_init_configured(font_pixel_height, render_config, settings.nerd_font_symbols, primary_family) if demo_mode else grimalkin_terminal_init_configured(font_pixel_height, render_config, settings.nerd_font_symbols, primary_family)
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
		fmt.panicf("GLFW could not find a Vulkan loader (%d): %s", code, description)
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
	app := Vulkan_App {
		demo                 = &demo,
		redraw               = true,
		focused              = true,
		framebuffer_readback = cursor_gpu_test,
		cursor_gpu_test      = cursor_gpu_test,
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
		fmt.panicf("window creation failed (%d): %s", code, description)
	}
	app.selection_text_cursor = glfw.CreateStandardCursor(glfw.IBEAM_CURSOR)
	app.selection_block_cursor = glfw.CreateStandardCursor(glfw.CROSSHAIR_CURSOR)
	defer if app.selection_text_cursor != nil do glfw.DestroyCursor(app.selection_text_cursor)
	defer if app.selection_block_cursor != nil do glfw.DestroyCursor(app.selection_block_cursor)
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
		if grimalkin_set_window_rounded_corners(rawptr(app.window)) == 0 {
			fmt.eprintln("Windows DWM did not enable rounded window corners")
		}
	}
	defer glfw.DestroyWindow(app.window)
	glfw.SetWindowUserPointer(app.window, &app)
	glfw.SetInputMode(app.window, glfw.LOCK_KEY_MODS, 1)
	glfw.SetKeyCallback(app.window, key_callback)
	glfw.SetCharCallback(app.window, char_callback)
	glfw.SetMouseButtonCallback(app.window, mouse_button_callback)
	glfw.SetCursorPosCallback(app.window, cursor_position_callback)
	glfw.SetScrollCallback(app.window, scroll_callback)
	glfw.SetFramebufferSizeCallback(app.window, framebuffer_size_callback)
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

	init_vulkan(&app)
	defer destroy_vulkan(&app)
	defer settings_flush(&app)

	benchmark_samples := Benchmark_Samples{}
	defer benchmark_samples_destroy(&benchmark_samples)
	frames_rendered := 0
	if cursor_gpu_test {
		run_cursor_gpu_tests(&app)
		return
	}
	when BENCHMARK_MODE {
		for !glfw.WindowShouldClose(app.window) {
			// Every context.temp_allocator value produced by initialization or the
			// previous frame is scratch. None of it is retained by app or demo.
			mem.free_all(context.temp_allocator)
			glfw.PollEvents()
			frame_time := glfw.GetTime()
			cursor_sample := sample_cursor_animation(&app, frame_time)
			indicator_sample := scroll_indicator_sample(
				&app.scroll_indicator,
				frame_time,
				demo.snapshot.viewport_active,
			)
			app.cursor_animation.next_sample_at = cursor_sample.next_sample_at
			sample := draw_frame(
				&app,
				cursor_sample.opacity,
				text_opacity = cursor_sample.text_opacity,
				scroll_indicator_opacity = indicator_sample.opacity,
			)
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
			if !demo.demo_mode {
				if terminal_session_drain(&demo.session, &demo.terminal) > 0 {
					_ = refresh_terminal_display(&app)
					selection_snapshot_updated(&app)
					app.redraw = true
				}
				process_terminal_clipboard(&app)
			}
			if app.display_rotation_check_pending &&
			   glfw.GetTime() >= app.display_rotation_check_deadline {
				app.display_rotation_check_pending = false
				refresh_display_rotation(&app)
			}
			if app.framebuffer_dirty {
				recreate_swapchain(&app)
				app.framebuffer_dirty = false
				app.redraw = true
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
				glfw.WaitEvents()
				flush_pending_key(&app)
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
				cursor_sample = sample_cursor_animation(&app, frame_time)
				indicator_sample = scroll_indicator_sample(
					&app.scroll_indicator,
					frame_time,
					demo.snapshot.viewport_active,
				)
				app.cursor_animation.next_sample_at = cursor_sample.next_sample_at
				_ = draw_frame(
					&app,
					cursor_sample.opacity,
					text_opacity = cursor_sample.text_opacity,
					scroll_indicator_opacity = indicator_sample.opacity,
				)
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
			if wait_deadline != max(f64) {
				timeout := max(0.001, wait_deadline - glfw.GetTime())
				glfw.WaitEventsTimeout(timeout)
			} else {
				glfw.WaitEvents()
			}
			flush_pending_key(&app)
		}
	}

	vk_must(vk.DeviceWaitIdle(app.device), "waiting for the device to become idle")
}

init_vulkan :: proc(app: ^Vulkan_App) {
	vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))
	if vk.CreateInstance == nil {
		fmt.panicf("Vulkan global procedure loading failed")
	}

	create_instance(app)
	vk.load_proc_addresses_instance(app.instance)
	create_debug_messenger(app)

	vk_must(
		glfw.CreateWindowSurface(app.instance, app.window, nil, &app.surface),
		"creating the GLFW window surface",
	)

	pick_physical_device(app)
	create_logical_device(app)
	vk.load_proc_addresses_device(app.device)

	create_swapchain(app)
	resize_terminal_to_extent(app)
	osd_prepare(app)
	create_render_pass(app)
	create_descriptor_layout(app)
	create_padding_glow_descriptor_layout(app)
	create_graphics_pipeline(app)
	create_padding_glow_source_render_pass(app)
	create_padding_glow_source_pipeline(app)
	create_padding_glow_background_pipeline(app)
	create_padding_glow_pipeline(app)
	create_osd_pipeline(app)
	create_selection_pipeline(app)
	create_scroll_indicator_pipeline(app)
	create_framebuffers(app)
	create_commands(app)
	create_padding_glow_source_resources(app)
	when BENCHMARK_MODE {
		create_timestamp_queries(app)
	}
	create_text_resources(app)
	if app.framebuffer_readback {
		create_capture_buffer(app)
	}
	create_synchronization(app)
}

text_grid_extent :: proc(app: ^Vulkan_App) -> vk.Extent2D {
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

text_render_area :: proc(app: ^Vulkan_App) -> vk.Rect2D {
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

resize_terminal_to_extent :: proc(app: ^Vulkan_App, force := false) {
	metrics := app.demo.resources.cell_metrics
	cols, rows, valid := grid_dimensions_for_framebuffer(
		app.extent.width,
		app.extent.height,
		metrics.cell_width,
		metrics.cell_height,
		u32(f32(app.settings.padding) * app.content_scale_x + 0.5),
		u32(f32(app.settings.padding) * app.content_scale_y + 0.5),
	)
	if !valid do return
	if !force && cols == app.demo.grid.cols && rows == app.demo.grid.rows do return
	selection_clear(&app.selection)
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

refresh_terminal_display :: proc(app: ^Vulkan_App) -> Display_Compile_Stats {
	stats := grimalkin_demo_refresh(app.demo) if app.demo.demo_mode else grimalkin_view_refresh(app.demo)
	if stats.glyph_cache_full {
		app.glyph_cache_reset_pending = true
		app.redraw = true
	}
	return stats
}

destroy_swapchain_resources :: proc(app: ^Vulkan_App) {
	destroy_buffer(app.device, &app.capture_buffer)
	if app.padding_glow_descriptor_pool != 0 {
		vk.DestroyDescriptorPool(app.device, app.padding_glow_descriptor_pool, nil)
		app.padding_glow_descriptor_pool = 0
	}
	if app.padding_glow_sampler != 0 {
		vk.DestroySampler(app.device, app.padding_glow_sampler, nil)
		app.padding_glow_sampler = 0
	}
	for &frame in app.frames {
		frame.padding_glow_descriptor_set = 0
		if frame.padding_glow_source_framebuffer != 0 {
			vk.DestroyFramebuffer(app.device, frame.padding_glow_source_framebuffer, nil)
		}
		if frame.padding_glow_source_attachment_view != 0 {
			vk.DestroyImageView(app.device, frame.padding_glow_source_attachment_view, nil)
		}
		if frame.padding_glow_source_view != 0 {
			vk.DestroyImageView(app.device, frame.padding_glow_source_view, nil)
		}
		if frame.padding_glow_source_image != 0 {
			vk.DestroyImage(app.device, frame.padding_glow_source_image, nil)
		}
		if frame.padding_glow_source_memory != 0 {
			vk.FreeMemory(app.device, frame.padding_glow_source_memory, nil)
		}
		frame.padding_glow_source_framebuffer = 0
		frame.padding_glow_source_attachment_view = 0
		frame.padding_glow_source_view = 0
		frame.padding_glow_source_image = 0
		frame.padding_glow_source_memory = 0
		if frame.padding_glow_background_framebuffer != 0 {
			vk.DestroyFramebuffer(app.device, frame.padding_glow_background_framebuffer, nil)
		}
		if frame.padding_glow_background_attachment_view != 0 {
			vk.DestroyImageView(app.device, frame.padding_glow_background_attachment_view, nil)
		}
		if frame.padding_glow_background_view != 0 {
			vk.DestroyImageView(app.device, frame.padding_glow_background_view, nil)
		}
		if frame.padding_glow_background_image != 0 {
			vk.DestroyImage(app.device, frame.padding_glow_background_image, nil)
		}
		if frame.padding_glow_background_memory != 0 {
			vk.FreeMemory(app.device, frame.padding_glow_background_memory, nil)
		}
		frame.padding_glow_background_framebuffer = 0
		frame.padding_glow_background_attachment_view = 0
		frame.padding_glow_background_view = 0
		frame.padding_glow_background_image = 0
		frame.padding_glow_background_memory = 0
	}
	for framebuffer in app.framebuffers do vk.DestroyFramebuffer(app.device, framebuffer, nil)
	delete(app.framebuffers)
	if app.pipeline != 0 do vk.DestroyPipeline(app.device, app.pipeline, nil)
	if app.pipeline_layout != 0 do vk.DestroyPipelineLayout(app.device, app.pipeline_layout, nil)
	if app.padding_glow_pipeline != 0 do vk.DestroyPipeline(app.device, app.padding_glow_pipeline, nil)
	if app.padding_glow_pipeline_layout != 0 do vk.DestroyPipelineLayout(app.device, app.padding_glow_pipeline_layout, nil)
	if app.padding_glow_source_pipeline != 0 do vk.DestroyPipeline(app.device, app.padding_glow_source_pipeline, nil)
	if app.padding_glow_background_pipeline != 0 do vk.DestroyPipeline(app.device, app.padding_glow_background_pipeline, nil)
	if app.padding_glow_source_render_pass != 0 do vk.DestroyRenderPass(app.device, app.padding_glow_source_render_pass, nil)
	if app.osd_pipeline != 0 do vk.DestroyPipeline(app.device, app.osd_pipeline, nil)
	if app.osd_pipeline_layout != 0 do vk.DestroyPipelineLayout(app.device, app.osd_pipeline_layout, nil)
	if app.selection_pipeline != 0 do vk.DestroyPipeline(app.device, app.selection_pipeline, nil)
	if app.selection_pipeline_layout != 0 do vk.DestroyPipelineLayout(app.device, app.selection_pipeline_layout, nil)
	if app.scroll_indicator_pipeline != 0 do vk.DestroyPipeline(app.device, app.scroll_indicator_pipeline, nil)
	if app.scroll_indicator_pipeline_layout != 0 do vk.DestroyPipelineLayout(app.device, app.scroll_indicator_pipeline_layout, nil)
	if app.render_pass != 0 do vk.DestroyRenderPass(app.device, app.render_pass, nil)
	app.pipeline = 0
	app.pipeline_layout = 0
	app.padding_glow_pipeline = 0
	app.padding_glow_pipeline_layout = 0
	app.padding_glow_source_pipeline = 0
	app.padding_glow_background_pipeline = 0
	app.padding_glow_source_render_pass = 0
	app.osd_pipeline = 0
	app.osd_pipeline_layout = 0
	app.selection_pipeline = 0
	app.selection_pipeline_layout = 0
	app.scroll_indicator_pipeline = 0
	app.scroll_indicator_pipeline_layout = 0
	app.render_pass = 0
	for image_view in app.image_views do vk.DestroyImageView(app.device, image_view, nil)
	delete(app.image_views)
	delete(app.swapchain_images)
	if app.swapchain != 0 do vk.DestroySwapchainKHR(app.device, app.swapchain, nil)
	app.swapchain = 0
}

recreate_swapchain :: proc(app: ^Vulkan_App) {
	width, height := glfw.GetFramebufferSize(app.window)
	if width <= 0 || height <= 0 do return
	vk_must(vk.DeviceWaitIdle(app.device), "waiting before swapchain recreation")
	for semaphore in app.render_finished do vk.DestroySemaphore(app.device, semaphore, nil)
	delete(app.render_finished)
	app.render_finished = nil
	destroy_swapchain_resources(app)
	create_swapchain(app)
	create_swapchain_image_synchronization(app)
	resize_terminal_to_extent(app)
	osd_prepare(app)
	create_render_pass(app)
	create_graphics_pipeline(app)
	create_padding_glow_source_render_pass(app)
	create_padding_glow_source_pipeline(app)
	create_padding_glow_background_pipeline(app)
	create_padding_glow_pipeline(app)
	create_osd_pipeline(app)
	create_selection_pipeline(app)
	create_scroll_indicator_pipeline(app)
	create_framebuffers(app)
	create_padding_glow_source_resources(app)
	if app.framebuffer_readback do create_capture_buffer(app)
	app.capture_complete = false
}

destroy_vulkan :: proc(app: ^Vulkan_App) {
	if app.device != nil {
		vk.DeviceWaitIdle(app.device)

		destroy_buffer(app.device, &app.staging_buffer)
		for &frame in app.frames {
			if frame.timestamp_pool != 0 do vk.DestroyQueryPool(app.device, frame.timestamp_pool, nil)
			destroy_buffer(app.device, &frame.visual_buffer)
			destroy_buffer(app.device, &frame.cell_buffer)
			destroy_buffer(app.device, &frame.decoration_buffer)
			destroy_buffer(app.device, &frame.osd_cell_buffer)
			destroy_buffer(app.device, &frame.selection_mask_buffer)
			vk.DestroyFence(app.device, frame.in_flight, nil)
			vk.DestroySemaphore(app.device, frame.image_available, nil)
		}
		for semaphore in app.render_finished do vk.DestroySemaphore(app.device, semaphore, nil)
		delete(app.render_finished)
		delete(app.images_in_flight)
		delete(app.frames)
		for &texture in app.texture_images {
			destroy_texture_image(app.device, &texture)
		}
		delete(app.texture_images)
		vk.DestroyDescriptorPool(app.device, app.descriptor_pool, nil)

		vk.DestroyCommandPool(app.device, app.command_pool, nil)
		vk.DestroyFence(app.device, app.upload_fence, nil)

		destroy_swapchain_resources(app)
		if app.padding_glow_descriptor_layout != 0 {
			vk.DestroyDescriptorSetLayout(app.device, app.padding_glow_descriptor_layout, nil)
		}
		vk.DestroyDescriptorSetLayout(app.device, app.descriptor_layout, nil)
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

destroy_gpu_text_resources :: proc(app: ^Vulkan_App) {
	for &frame in app.frames {
		destroy_buffer(app.device, &frame.visual_buffer)
		destroy_buffer(app.device, &frame.cell_buffer)
		destroy_buffer(app.device, &frame.decoration_buffer)
		destroy_buffer(app.device, &frame.osd_cell_buffer)
		destroy_buffer(app.device, &frame.selection_mask_buffer)
		frame.descriptor_set = 0
		frame.osd_descriptor_set = 0
		frame.selection_descriptor_set = 0
		frame.cell_capacity = 0
		frame.decoration_capacity = 0
		frame.osd_cell_capacity = 0
		frame.selection_mask_capacity = 0
		frame.visual_capacity = 0
		frame.visuals_uploaded = 0
	}
	for &texture in app.texture_images do destroy_texture_image(app.device, &texture)
	delete(app.texture_images)
	app.texture_images = nil
	if app.descriptor_pool != 0 do vk.DestroyDescriptorPool(app.device, app.descriptor_pool, nil)
	app.descriptor_pool = 0
}

reset_text_resource_command_buffers :: proc(app: ^Vulkan_App) {
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

apply_pending_settings :: proc(app: ^Vulkan_App) {
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
		replacement.textures.maximum_image_dimension_2d = properties.limits.maxImageDimension2D
		replacement.textures.maximum_array_layers = properties.limits.maxImageArrayLayers
		for resource in replacement.textures.resources {
			if resource != nil do resource.maximum_layers = properties.limits.maxImageArrayLayers
		}
		if replacement.glyph_atlas.packer.maximum_layers == 0 ||
		   replacement.glyph_atlas.packer.maximum_layers > properties.limits.maxImageArrayLayers {
			replacement.glyph_atlas.packer.maximum_layers = properties.limits.maxImageArrayLayers
		}
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
		resize_terminal_to_extent(app, true)
		_ = refresh_terminal_display(app)
		osd_prepare(app)
		create_text_resources(app)
	}
	if app.settings_layout_pending {
		resize_terminal_to_extent(app)
		app.settings_layout_pending = false
	}
	app.redraw = true
}

create_instance :: proc(app: ^Vulkan_App) {
	application_info := vk.ApplicationInfo {
		sType              = .APPLICATION_INFO,
		pApplicationName   = "Grimalkin",
		applicationVersion = vk.MAKE_VERSION(0, 1, 0),
		pEngineName        = "Grimalkin Renderer",
		engineVersion      = vk.MAKE_VERSION(0, 1, 0),
		apiVersion         = vk.API_VERSION_1_2,
	}

	extensions := slice.clone_to_dynamic(
		glfw.GetRequiredInstanceExtensions(),
		context.temp_allocator,
	)
	when ODIN_OS == .Darwin {
		append(&extensions, vk.KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)
	}
	when ENABLE_VALIDATION {
		append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
	}

	create_info := vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		pApplicationInfo        = &application_info,
		enabledExtensionCount   = u32(len(extensions)),
		ppEnabledExtensionNames = raw_data(extensions),
	}

	when ODIN_OS == .Darwin {
		create_info.flags |= {.ENUMERATE_PORTABILITY_KHR}
	}

	when ENABLE_VALIDATION {
		validation_layers := []cstring{"VK_LAYER_KHRONOS_validation"}
		create_info.enabledLayerCount = u32(len(validation_layers))
		create_info.ppEnabledLayerNames = raw_data(validation_layers)

		debug_info := debug_messenger_create_info()
		create_info.pNext = &debug_info
	}

	vk_must(vk.CreateInstance(&create_info, nil, &app.instance), "creating the Vulkan instance")
}

create_debug_messenger :: proc(app: ^Vulkan_App) {
	when ENABLE_VALIDATION {
		create_info := debug_messenger_create_info()
		vk_must(
			vk.CreateDebugUtilsMessengerEXT(app.instance, &create_info, nil, &app.debug_messenger),
			"creating the Vulkan debug messenger",
		)
	}
}

debug_messenger_create_info :: proc() -> vk.DebugUtilsMessengerCreateInfoEXT {
	return vk.DebugUtilsMessengerCreateInfoEXT {
		sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
		messageSeverity = {.WARNING, .ERROR},
		messageType = {.GENERAL, .VALIDATION, .PERFORMANCE},
		pfnUserCallback = vulkan_debug_callback,
	}
}

vulkan_debug_callback :: proc "system" (
	severity: vk.DebugUtilsMessageSeverityFlagsEXT,
	message_types: vk.DebugUtilsMessageTypeFlagsEXT,
	callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT,
	user_data: rawptr,
) -> b32 {
	context = runtime.default_context()
	fmt.eprintfln("Vulkan [%v, %v]: %s", severity, message_types, callback_data.pMessage)
	return false
}

pick_physical_device :: proc(app: ^Vulkan_App) {
	device_count: u32
	vk_must(
		vk.EnumeratePhysicalDevices(app.instance, &device_count, nil),
		"counting physical devices",
	)
	if device_count == 0 {
		fmt.panicf("no Vulkan-capable device was found")
	}

	devices := make([]vk.PhysicalDevice, device_count, context.temp_allocator)
	vk_must(
		vk.EnumeratePhysicalDevices(app.instance, &device_count, raw_data(devices)),
		"enumerating physical devices",
	)

	preference := os.get_env("GRIMALKIN_GPU_TEST_DEVICE", context.temp_allocator)
	if preference != "" && preference != "cpu" && preference != "hardware" && preference != "any" {
		fmt.panicf("GRIMALKIN_GPU_TEST_DEVICE must be cpu, hardware, or any; got %q", preference)
	}
	pass_count := 1
	if app.cursor_gpu_test && preference == "" do pass_count = 2
	for pass := 0; pass < pass_count; pass += 1 {
		require_cpu := preference == "cpu" || (app.cursor_gpu_test && preference == "" && pass == 0)
		require_hardware := preference == "hardware"
		for device in devices {
			properties: vk.PhysicalDeviceProperties
			vk.GetPhysicalDeviceProperties(device, &properties)
			if require_cpu && properties.deviceType != .CPU do continue
			if require_hardware && properties.deviceType == .CPU do continue

			families := find_queue_families(app, device)
			if !families.has_graphics ||
			   !families.has_present ||
			   !supports_required_extensions(device) ||
			   !supports_descriptor_indexing(device) {
				continue
			}

			format_count, present_mode_count := swapchain_option_counts(app, device)
			if format_count == 0 || present_mode_count == 0 {
				continue
			}

			app.physical_device = device
			app.queue_families = families
			app.texture_capacity = min(
				MAX_TEXTURE_RESOURCES_CAP,
				properties.limits.maxPerStageDescriptorSampledImages,
				properties.limits.maxDescriptorSetSampledImages,
			)
			if app.texture_capacity == 0 do continue
			app.demo.resources.textures.maximum_count = int(app.texture_capacity)
			app.demo.resources.textures.maximum_image_dimension_2d = properties.limits.maxImageDimension2D
			app.demo.resources.textures.maximum_array_layers = properties.limits.maxImageArrayLayers
			for resource in app.demo.resources.textures.resources {
				if resource != nil do resource.maximum_layers = properties.limits.maxImageArrayLayers
			}
			if app.demo.resources.glyph_atlas.packer.maximum_layers == 0 ||
			   app.demo.resources.glyph_atlas.packer.maximum_layers > properties.limits.maxImageArrayLayers {
				app.demo.resources.glyph_atlas.packer.maximum_layers = properties.limits.maxImageArrayLayers
			}
			fmt.printfln("Using Vulkan device: %s", fixed_byte_string(&properties.deviceName))
			fmt.printfln("Texture descriptor capacity: %d", app.texture_capacity)
			return
		}
	}

	fmt.panicf(
		"no Vulkan 1.2 device supports swapchains plus non-uniform sampled-image indexing, runtime descriptor arrays, partially-bound descriptors, and variable descriptor counts",
	)
}

supports_descriptor_indexing :: proc(device: vk.PhysicalDevice) -> bool {
	indexing := vk.PhysicalDeviceDescriptorIndexingFeatures {
		sType = .PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_FEATURES,
	}
	features := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &indexing,
	}
	vk.GetPhysicalDeviceFeatures2(device, &features)
	return(
		bool(indexing.shaderSampledImageArrayNonUniformIndexing) &&
		bool(indexing.descriptorBindingPartiallyBound) &&
		bool(indexing.descriptorBindingVariableDescriptorCount) &&
		bool(indexing.runtimeDescriptorArray) \
	)
}

find_queue_families :: proc(app: ^Vulkan_App, device: vk.PhysicalDevice) -> Queue_Families {
	result := Queue_Families{}
	count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, nil)

	properties := make([]vk.QueueFamilyProperties, count, context.temp_allocator)
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, raw_data(properties))

	for property, index in properties {
		if .GRAPHICS in property.queueFlags {
			result.graphics = u32(index)
			result.has_graphics = true
		}

		present_supported: b32
		vk_must(
			vk.GetPhysicalDeviceSurfaceSupportKHR(
				device,
				u32(index),
				app.surface,
				&present_supported,
			),
			"querying presentation support",
		)
		if present_supported {
			result.present = u32(index)
			result.has_present = true
		}

		if result.has_graphics && result.has_present {
			break
		}
	}

	return result
}

supports_required_extensions :: proc(device: vk.PhysicalDevice) -> bool {
	count: u32
	if vk.EnumerateDeviceExtensionProperties(device, nil, &count, nil) != .SUCCESS {
		return false
	}

	available := make([]vk.ExtensionProperties, count, context.temp_allocator)
	if vk.EnumerateDeviceExtensionProperties(device, nil, &count, raw_data(available)) !=
	   .SUCCESS {
		return false
	}

	if !has_extension(available, vk.KHR_SWAPCHAIN_EXTENSION_NAME) {
		return false
	}
	when ODIN_OS == .Darwin {
		if !has_extension(available, vk.KHR_PORTABILITY_SUBSET_EXTENSION_NAME) {
			return false
		}
	}
	return true
}

has_extension :: proc(available: []vk.ExtensionProperties, wanted: cstring) -> bool {
	for &extension in available {
		if fixed_byte_string(&extension.extensionName) == string(wanted) {
			return true
		}
	}
	return false
}

swapchain_option_counts :: proc(app: ^Vulkan_App, device: vk.PhysicalDevice) -> (u32, u32) {
	format_count, present_mode_count: u32
	if vk.GetPhysicalDeviceSurfaceFormatsKHR(device, app.surface, &format_count, nil) != .SUCCESS {
		return 0, 0
	}
	if vk.GetPhysicalDeviceSurfacePresentModesKHR(device, app.surface, &present_mode_count, nil) !=
	   .SUCCESS {
		return 0, 0
	}
	return format_count, present_mode_count
}

create_logical_device :: proc(app: ^Vulkan_App) {
	priority := f32(1.0)
	queue_infos: [2]vk.DeviceQueueCreateInfo
	queue_infos[0] = vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = app.queue_families.graphics,
		queueCount       = 1,
		pQueuePriorities = &priority,
	}
	queue_info_count: u32 = 1

	if app.queue_families.present != app.queue_families.graphics {
		queue_infos[1] = vk.DeviceQueueCreateInfo {
			sType            = .DEVICE_QUEUE_CREATE_INFO,
			queueFamilyIndex = app.queue_families.present,
			queueCount       = 1,
			pQueuePriorities = &priority,
		}
		queue_info_count = 2
	}

	device_extensions: [2]cstring
	device_extensions[0] = vk.KHR_SWAPCHAIN_EXTENSION_NAME
	device_extension_count: u32 = 1
	when ODIN_OS == .Darwin {
		device_extensions[1] = vk.KHR_PORTABILITY_SUBSET_EXTENSION_NAME
		device_extension_count = 2
	}

	indexing := vk.PhysicalDeviceDescriptorIndexingFeatures {
		sType                                     = .PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_FEATURES,
		shaderSampledImageArrayNonUniformIndexing = true,
		descriptorBindingPartiallyBound           = true,
		descriptorBindingVariableDescriptorCount  = true,
		runtimeDescriptorArray                    = true,
	}
	create_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &indexing,
		queueCreateInfoCount    = queue_info_count,
		pQueueCreateInfos       = &queue_infos[0],
		enabledExtensionCount   = device_extension_count,
		ppEnabledExtensionNames = &device_extensions[0],
	}

	vk_must(
		vk.CreateDevice(app.physical_device, &create_info, nil, &app.device),
		"creating the logical device",
	)
	vk.GetDeviceQueue(app.device, app.queue_families.graphics, 0, &app.graphics_queue)
	vk.GetDeviceQueue(app.device, app.queue_families.present, 0, &app.present_queue)
}

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

create_graphics_pipeline :: proc(app: ^Vulkan_App) {
	vertex_module := create_shader_module(app.device, VERTEX_SHADER)
	defer vk.DestroyShaderModule(app.device, vertex_module, nil)
	fragment_module := create_shader_module(app.device, FRAGMENT_SHADER)
	defer vk.DestroyShaderModule(app.device, fragment_module, nil)

	shader_stages := [2]vk.PipelineShaderStageCreateInfo {
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.VERTEX},
			module = vertex_module,
			pName = "main",
		},
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.FRAGMENT},
			module = fragment_module,
			pName = "main",
		},
	}

	vertex_input := vk.PipelineVertexInputStateCreateInfo {
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
	}
	input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
		sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_STRIP,
	}
	viewport_state := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1,
	}
	rasterization := vk.PipelineRasterizationStateCreateInfo {
		sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = .FILL,
		lineWidth   = 1.0,
		frontFace   = .CLOCKWISE,
	}
	multisampling := vk.PipelineMultisampleStateCreateInfo {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
	}
	colour_blend_attachment := vk.PipelineColorBlendAttachmentState {
		colorWriteMask = {.R, .G, .B, .A},
	}
	colour_blending := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &colour_blend_attachment,
	}
	dynamic_states := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_state := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(dynamic_states)),
		pDynamicStates    = &dynamic_states[0],
	}

	push_range := vk.PushConstantRange {
		stageFlags = {.FRAGMENT},
		size       = u32(size_of(Text_Layout_Push)),
	}
	layout_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 1,
		pSetLayouts            = &app.descriptor_layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &push_range,
	}
	vk_must(
		vk.CreatePipelineLayout(app.device, &layout_info, nil, &app.pipeline_layout),
		"creating the pipeline layout",
	)

	pipeline_info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount          = u32(len(shader_stages)),
		pStages             = &shader_stages[0],
		pVertexInputState   = &vertex_input,
		pInputAssemblyState = &input_assembly,
		pViewportState      = &viewport_state,
		pRasterizationState = &rasterization,
		pMultisampleState   = &multisampling,
		pColorBlendState    = &colour_blending,
		pDynamicState       = &dynamic_state,
		layout              = app.pipeline_layout,
		renderPass          = app.render_pass,
		subpass             = 0,
		basePipelineIndex   = -1,
	}
	vk_must(
		vk.CreateGraphicsPipelines(app.device, 0, 1, &pipeline_info, nil, &app.pipeline),
		"creating the graphics pipeline",
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
	vertex_module := create_shader_module(app.device, VERTEX_SHADER)
	defer vk.DestroyShaderModule(app.device, vertex_module, nil)
	fragment_module := create_shader_module(app.device, fragment_shader)
	defer vk.DestroyShaderModule(app.device, fragment_module, nil)
	stages := [2]vk.PipelineShaderStageCreateInfo {
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX}, module = vertex_module, pName = "main"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = fragment_module, pName = "main"},
	}
	vertex_input := vk.PipelineVertexInputStateCreateInfo{sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO}
	assembly := vk.PipelineInputAssemblyStateCreateInfo{sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, topology = .TRIANGLE_STRIP}
	viewport := vk.PipelineViewportStateCreateInfo{sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO, viewportCount = 1, scissorCount = 1}
	raster := vk.PipelineRasterizationStateCreateInfo{sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO, polygonMode = .FILL, lineWidth = 1, frontFace = .CLOCKWISE}
	multisample := vk.PipelineMultisampleStateCreateInfo{sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, rasterizationSamples = {._1}}
	colour_attachment := vk.PipelineColorBlendAttachmentState{colorWriteMask = {.R, .G, .B, .A}}
	colour_blend := vk.PipelineColorBlendStateCreateInfo {
		sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments = &colour_attachment,
	}
	dynamic_states := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_info := vk.PipelineDynamicStateCreateInfo {
		sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(dynamic_states)),
		pDynamicStates = &dynamic_states[0],
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
		pColorBlendState = &colour_blend,
		pDynamicState = &dynamic_info,
		layout = app.pipeline_layout,
		renderPass = app.padding_glow_source_render_pass,
		subpass = 0,
		basePipelineIndex = -1,
	}
	vk_must(
		vk.CreateGraphicsPipelines(
			app.device,
			0,
			1,
			&pipeline_info,
			nil,
			pipeline,
		),
		"creating the padding glow source graphics pipeline",
	)
}

create_padding_glow_pipeline :: proc(app: ^Vulkan_App) {
	vertex_module := create_shader_module(app.device, PADDING_GLOW_VERTEX_SHADER)
	defer vk.DestroyShaderModule(app.device, vertex_module, nil)
	fragment_module := create_shader_module(app.device, PADDING_GLOW_FRAGMENT_SHADER)
	defer vk.DestroyShaderModule(app.device, fragment_module, nil)
	stages := [2]vk.PipelineShaderStageCreateInfo {
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX}, module = vertex_module, pName = "main"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = fragment_module, pName = "main"},
	}
	vertex_input := vk.PipelineVertexInputStateCreateInfo{sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO}
	assembly := vk.PipelineInputAssemblyStateCreateInfo{sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, topology = .TRIANGLE_STRIP}
	viewport := vk.PipelineViewportStateCreateInfo{sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO, viewportCount = 1, scissorCount = 1}
	raster := vk.PipelineRasterizationStateCreateInfo{sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO, polygonMode = .FILL, lineWidth = 1, frontFace = .CLOCKWISE}
	multisample := vk.PipelineMultisampleStateCreateInfo{sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, rasterizationSamples = {._1}}
	colour_attachment := vk.PipelineColorBlendAttachmentState{colorWriteMask = {.R, .G, .B, .A}}
	colour_blend := vk.PipelineColorBlendStateCreateInfo {
		sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments = &colour_attachment,
	}
	dynamic_states := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_info := vk.PipelineDynamicStateCreateInfo {
		sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(dynamic_states)),
		pDynamicStates = &dynamic_states[0],
	}
	push_range := vk.PushConstantRange{stageFlags = {.FRAGMENT}, size = u32(size_of(Padding_Glow_Push))}
	layout_info := vk.PipelineLayoutCreateInfo {
		sType = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount = 1,
		pSetLayouts = &app.padding_glow_descriptor_layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges = &push_range,
	}
	vk_must(
		vk.CreatePipelineLayout(app.device, &layout_info, nil, &app.padding_glow_pipeline_layout),
		"creating the padding glow pipeline layout",
	)
	pipeline_info := vk.GraphicsPipelineCreateInfo {
		sType = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount = u32(len(stages)),
		pStages = &stages[0],
		pVertexInputState = &vertex_input,
		pInputAssemblyState = &assembly,
		pViewportState = &viewport,
		pRasterizationState = &raster,
		pMultisampleState = &multisample,
		pColorBlendState = &colour_blend,
		pDynamicState = &dynamic_info,
		layout = app.padding_glow_pipeline_layout,
		renderPass = app.render_pass,
		subpass = 0,
		basePipelineIndex = -1,
	}
	vk_must(
		vk.CreateGraphicsPipelines(app.device, 0, 1, &pipeline_info, nil, &app.padding_glow_pipeline),
		"creating the padding glow graphics pipeline",
	)
}

create_osd_pipeline :: proc(app: ^Vulkan_App) {
	vertex_module := create_shader_module(app.device, OSD_VERTEX_SHADER)
	defer vk.DestroyShaderModule(app.device, vertex_module, nil)
	fragment_module := create_shader_module(app.device, OSD_FRAGMENT_SHADER)
	defer vk.DestroyShaderModule(app.device, fragment_module, nil)
	stages := [2]vk.PipelineShaderStageCreateInfo {
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX}, module = vertex_module, pName = "main"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = fragment_module, pName = "main"},
	}
	vertex_input := vk.PipelineVertexInputStateCreateInfo{sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO}
	assembly := vk.PipelineInputAssemblyStateCreateInfo{sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, topology = .TRIANGLE_STRIP}
	viewport := vk.PipelineViewportStateCreateInfo{sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO, viewportCount = 1, scissorCount = 1}
	raster := vk.PipelineRasterizationStateCreateInfo{sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO, polygonMode = .FILL, lineWidth = 1, frontFace = .CLOCKWISE}
	multisample := vk.PipelineMultisampleStateCreateInfo{sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, rasterizationSamples = {._1}}
	blend_attachment := vk.PipelineColorBlendAttachmentState {
		blendEnable = true,
		srcColorBlendFactor = .ONE,
		dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
		colorBlendOp = .ADD,
		srcAlphaBlendFactor = .ONE,
		dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
		alphaBlendOp = .ADD,
		colorWriteMask = {.R, .G, .B, .A},
	}
	blend := vk.PipelineColorBlendStateCreateInfo{sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, attachmentCount = 1, pAttachments = &blend_attachment}
	dynamic_states := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_info := vk.PipelineDynamicStateCreateInfo{sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO, dynamicStateCount = 2, pDynamicStates = &dynamic_states[0]}
	push_range := vk.PushConstantRange{stageFlags = {.FRAGMENT}, size = u32(size_of(Osd_Push))}
	layout_info := vk.PipelineLayoutCreateInfo {
		sType = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount = 1,
		pSetLayouts = &app.descriptor_layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges = &push_range,
	}
	vk_must(vk.CreatePipelineLayout(app.device, &layout_info, nil, &app.osd_pipeline_layout), "creating the OSD pipeline layout")
	pipeline_info := vk.GraphicsPipelineCreateInfo {
		sType = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount = 2, pStages = &stages[0],
		pVertexInputState = &vertex_input, pInputAssemblyState = &assembly,
		pViewportState = &viewport, pRasterizationState = &raster,
		pMultisampleState = &multisample, pColorBlendState = &blend,
		pDynamicState = &dynamic_info, layout = app.osd_pipeline_layout,
		renderPass = app.render_pass, subpass = 0, basePipelineIndex = -1,
	}
	vk_must(vk.CreateGraphicsPipelines(app.device, 0, 1, &pipeline_info, nil, &app.osd_pipeline), "creating the OSD graphics pipeline")
}

create_selection_pipeline :: proc(app: ^Vulkan_App) {
	vertex_module := create_shader_module(app.device, SELECTION_VERTEX_SHADER)
	defer vk.DestroyShaderModule(app.device, vertex_module, nil)
	fragment_module := create_shader_module(app.device, SELECTION_FRAGMENT_SHADER)
	defer vk.DestroyShaderModule(app.device, fragment_module, nil)
	stages := [2]vk.PipelineShaderStageCreateInfo {
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX}, module = vertex_module, pName = "main"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = fragment_module, pName = "main"},
	}
	vertex_input := vk.PipelineVertexInputStateCreateInfo{sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO}
	assembly := vk.PipelineInputAssemblyStateCreateInfo{sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, topology = .TRIANGLE_STRIP}
	viewport := vk.PipelineViewportStateCreateInfo{sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO, viewportCount = 1, scissorCount = 1}
	raster := vk.PipelineRasterizationStateCreateInfo{sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO, polygonMode = .FILL, lineWidth = 1, frontFace = .CLOCKWISE}
	multisample := vk.PipelineMultisampleStateCreateInfo{sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, rasterizationSamples = {._1}}
	blend_attachment := vk.PipelineColorBlendAttachmentState {
		blendEnable = true,
		srcColorBlendFactor = .ONE,
		dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
		colorBlendOp = .ADD,
		srcAlphaBlendFactor = .ONE,
		dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
		alphaBlendOp = .ADD,
		colorWriteMask = {.R, .G, .B, .A},
	}
	blend := vk.PipelineColorBlendStateCreateInfo{sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, attachmentCount = 1, pAttachments = &blend_attachment}
	dynamic_states := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_info := vk.PipelineDynamicStateCreateInfo{sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO, dynamicStateCount = 2, pDynamicStates = &dynamic_states[0]}
	push_range := vk.PushConstantRange{stageFlags = {.FRAGMENT}, size = u32(size_of(Selection_Push))}
	layout_info := vk.PipelineLayoutCreateInfo {
		sType = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount = 1,
		pSetLayouts = &app.descriptor_layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges = &push_range,
	}
	vk_must(
		vk.CreatePipelineLayout(app.device, &layout_info, nil, &app.selection_pipeline_layout),
		"creating the selection pipeline layout",
	)
	pipeline_info := vk.GraphicsPipelineCreateInfo {
		sType = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount = 2,
		pStages = &stages[0],
		pVertexInputState = &vertex_input,
		pInputAssemblyState = &assembly,
		pViewportState = &viewport,
		pRasterizationState = &raster,
		pMultisampleState = &multisample,
		pColorBlendState = &blend,
		pDynamicState = &dynamic_info,
		layout = app.selection_pipeline_layout,
		renderPass = app.render_pass,
		subpass = 0,
		basePipelineIndex = -1,
	}
	vk_must(
		vk.CreateGraphicsPipelines(app.device, 0, 1, &pipeline_info, nil, &app.selection_pipeline),
		"creating the selection graphics pipeline",
	)
}

create_scroll_indicator_pipeline :: proc(app: ^Vulkan_App) {
	vertex_module := create_shader_module(app.device, OSD_VERTEX_SHADER)
	defer vk.DestroyShaderModule(app.device, vertex_module, nil)
	fragment_module := create_shader_module(app.device, SCROLL_INDICATOR_FRAGMENT_SHADER)
	defer vk.DestroyShaderModule(app.device, fragment_module, nil)
	stages := [2]vk.PipelineShaderStageCreateInfo {
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX}, module = vertex_module, pName = "main"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = fragment_module, pName = "main"},
	}
	vertex_input := vk.PipelineVertexInputStateCreateInfo{sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO}
	assembly := vk.PipelineInputAssemblyStateCreateInfo{sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, topology = .TRIANGLE_STRIP}
	viewport := vk.PipelineViewportStateCreateInfo{sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO, viewportCount = 1, scissorCount = 1}
	raster := vk.PipelineRasterizationStateCreateInfo{sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO, polygonMode = .FILL, lineWidth = 1, frontFace = .CLOCKWISE}
	multisample := vk.PipelineMultisampleStateCreateInfo{sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, rasterizationSamples = {._1}}
	blend_attachment := vk.PipelineColorBlendAttachmentState {
		blendEnable = true,
		srcColorBlendFactor = .ONE,
		dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
		colorBlendOp = .ADD,
		srcAlphaBlendFactor = .ONE,
		dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
		alphaBlendOp = .ADD,
		colorWriteMask = {.R, .G, .B, .A},
	}
	blend := vk.PipelineColorBlendStateCreateInfo{sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, attachmentCount = 1, pAttachments = &blend_attachment}
	dynamic_states := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_info := vk.PipelineDynamicStateCreateInfo{sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO, dynamicStateCount = 2, pDynamicStates = &dynamic_states[0]}
	push_range := vk.PushConstantRange{stageFlags = {.FRAGMENT}, size = u32(size_of(Scroll_Indicator_Push))}
	layout_info := vk.PipelineLayoutCreateInfo {
		sType = .PIPELINE_LAYOUT_CREATE_INFO,
		pushConstantRangeCount = 1,
		pPushConstantRanges = &push_range,
	}
	vk_must(
		vk.CreatePipelineLayout(app.device, &layout_info, nil, &app.scroll_indicator_pipeline_layout),
		"creating the scroll indicator pipeline layout",
	)
	pipeline_info := vk.GraphicsPipelineCreateInfo {
		sType = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount = 2,
		pStages = &stages[0],
		pVertexInputState = &vertex_input,
		pInputAssemblyState = &assembly,
		pViewportState = &viewport,
		pRasterizationState = &raster,
		pMultisampleState = &multisample,
		pColorBlendState = &blend,
		pDynamicState = &dynamic_info,
		layout = app.scroll_indicator_pipeline_layout,
		renderPass = app.render_pass,
		subpass = 0,
		basePipelineIndex = -1,
	}
	vk_must(
		vk.CreateGraphicsPipelines(app.device, 0, 1, &pipeline_info, nil, &app.scroll_indicator_pipeline),
		"creating the scroll indicator graphics pipeline",
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

create_padding_glow_source_target :: proc(
	app: ^Vulkan_App,
	image: ^vk.Image,
	memory: ^vk.DeviceMemory,
	sampled_view: ^vk.ImageView,
	attachment_view: ^vk.ImageView,
	framebuffer: ^vk.Framebuffer,
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
	vk_must(vk.CreateImage(app.device, &image_info, nil, image), "creating a padding glow source image")
	requirements: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(app.device, image^, &requirements)
	allocate_info := vk.MemoryAllocateInfo {
		sType = .MEMORY_ALLOCATE_INFO,
		allocationSize = requirements.size,
		memoryTypeIndex = find_memory_type(app, requirements.memoryTypeBits, {.DEVICE_LOCAL}),
	}
	vk_must(vk.AllocateMemory(app.device, &allocate_info, nil, memory), "allocating padding glow source memory")
	vk_must(vk.BindImageMemory(app.device, image^, memory^, 0), "binding padding glow source memory")
	attachment_view_info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = image^,
		viewType = .D2,
		format = PADDING_GLOW_SOURCE_FORMAT,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	vk_must(
		vk.CreateImageView(app.device, &attachment_view_info, nil, attachment_view),
		"creating a padding glow source attachment view",
	)
	sampled_view_info := attachment_view_info
	sampled_view_info.subresourceRange.levelCount = 1
	vk_must(
		vk.CreateImageView(app.device, &sampled_view_info, nil, sampled_view),
		"creating a padding glow source sampled view",
	)
	framebuffer_info := vk.FramebufferCreateInfo {
		sType = .FRAMEBUFFER_CREATE_INFO,
		renderPass = app.padding_glow_source_render_pass,
		attachmentCount = 1,
		pAttachments = attachment_view,
		width = app.extent.width,
		height = app.extent.height,
		layers = 1,
	}
	vk_must(
		vk.CreateFramebuffer(app.device, &framebuffer_info, nil, framebuffer),
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
		create_padding_glow_source_target(
			app,
			&frame.padding_glow_source_image,
			&frame.padding_glow_source_memory,
			&frame.padding_glow_source_view,
			&frame.padding_glow_source_attachment_view,
			&frame.padding_glow_source_framebuffer,
		)
		create_padding_glow_source_target(
			app,
			&frame.padding_glow_background_image,
			&frame.padding_glow_background_memory,
			&frame.padding_glow_background_view,
			&frame.padding_glow_background_attachment_view,
			&frame.padding_glow_background_framebuffer,
		)
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
			imageView = frame.padding_glow_source_view,
			imageLayout = .SHADER_READ_ONLY_OPTIMAL,
			},
			{
				sampler = app.padding_glow_sampler,
				imageView = frame.padding_glow_background_view,
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

find_memory_type :: proc(
	app: ^Vulkan_App,
	type_bits: u32,
	required: vk.MemoryPropertyFlags,
) -> u32 {
	properties: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(app.physical_device, &properties)
	for index := u32(0); index < properties.memoryTypeCount; index += 1 {
		available := properties.memoryTypes[index].propertyFlags
		if type_bits & (u32(1) << index) != 0 && (available & required) == required {
			return index
		}
	}
	fmt.panicf("no Vulkan memory type satisfies %v", required)
}

create_buffer :: proc(
	app: ^Vulkan_App,
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
	vk_must(vk.CreateBuffer(app.device, &create_info, nil, &buffer.handle), "creating a buffer")

	requirements: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(app.device, buffer.handle, &requirements)
	allocate_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = requirements.size,
		memoryTypeIndex = find_memory_type(app, requirements.memoryTypeBits, properties),
	}
	vk_must(
		vk.AllocateMemory(app.device, &allocate_info, nil, &buffer.memory),
		"allocating buffer memory",
	)
	vk_must(
		vk.BindBufferMemory(app.device, buffer.handle, buffer.memory, 0),
		"binding buffer memory",
	)
	if map_memory {
		vk_must(
			vk.MapMemory(app.device, buffer.memory, 0, size, {}, &buffer.mapped),
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

capture_format_supported :: proc(format: vk.Format) -> bool {
	#partial switch format {
	case .B8G8R8A8_SRGB, .B8G8R8A8_UNORM, .R8G8B8A8_SRGB, .R8G8B8A8_UNORM:
		return true
	case:
		return false
	}
}

framebuffer_pixels_to_rgba :: proc(
	source: []u8,
	format: vk.Format,
	allocator := context.allocator,
) -> []u8 {
	if len(source) % 4 != 0 {
		fmt.panicf("framebuffer readback has %d bytes; expected four-byte pixels", len(source))
	}
	if !capture_format_supported(format) {
		fmt.panicf("framebuffer capture does not support Vulkan format %v", format)
	}
	pixels := make([]u8, len(source), allocator)
	if format == .R8G8B8A8_SRGB || format == .R8G8B8A8_UNORM {
		copy(pixels, source)
		return pixels
	}
	for offset := 0; offset < len(source); offset += 4 {
		pixels[offset + 0] = source[offset + 2]
		pixels[offset + 1] = source[offset + 1]
		pixels[offset + 2] = source[offset + 0]
		pixels[offset + 3] = source[offset + 3]
	}
	return pixels
}

create_capture_buffer :: proc(app: ^Vulkan_App) {
	if !capture_format_supported(app.surface_format.format) {
		fmt.panicf(
			"framebuffer capture does not support swapchain format %v",
			app.surface_format.format,
		)
	}
	byte_count, valid_byte_count := texture_byte_count(app.extent.width, app.extent.height, 1, 4)
	if !valid_byte_count do fmt.panicf("framebuffer capture dimensions are invalid")
	app.capture_buffer = create_buffer(
		app,
		vk.DeviceSize(byte_count),
		{.TRANSFER_DST},
		{.HOST_VISIBLE, .HOST_COHERENT},
		true,
	)
}

write_frame_capture :: proc(app: ^Vulkan_App) {
	pixels := read_framebuffer_pixels(app, context.temp_allocator)
	c_path, path_error := strings.clone_to_cstring(app.capture_path, context.temp_allocator)
	if path_error != nil {
		fmt.panicf("cannot allocate framebuffer capture path: %v", path_error)
	}
	if grimalkin_write_png_rgba(
		   c_path,
		   app.extent.width,
		   app.extent.height,
		   raw_data(pixels),
		   c.size_t(app.extent.width * 4),
	   ) !=
	   0 {
		fmt.panicf("could not write Vulkan framebuffer capture to %s", app.capture_path)
	}
	fmt.printfln(
		"Captured Vulkan framebuffer: %s (%dx%d %v)",
		app.capture_path,
		app.extent.width,
		app.extent.height,
		app.surface_format.format,
	)
}

read_framebuffer_pixels :: proc(
	app: ^Vulkan_App,
	allocator := context.allocator,
) -> []u8 {
	source := mem.byte_slice(app.capture_buffer.mapped, int(app.capture_buffer.size))
	return framebuffer_pixels_to_rgba(source, app.surface_format.format, allocator)
}

texture_vulkan_format :: proc(resource: ^Texture_Resource) -> vk.Format {
	if resource.format == .Mask_R8 do return .R8_UNORM
	return resource.encoding == .SRGB ? .R8G8B8A8_SRGB : .R8G8B8A8_UNORM
}

create_texture_image :: proc(app: ^Vulkan_App, resource: ^Texture_Resource) -> Gpu_Texture_Image {
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
		memoryTypeIndex = find_memory_type(app, requirements.memoryTypeBits, {.DEVICE_LOCAL}),
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

create_descriptor_sets :: proc(app: ^Vulkan_App) {
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

update_selection_descriptor_set :: proc(app: ^Vulkan_App, frame: ^Frame_Context) {
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
	app: ^Vulkan_App,
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

update_text_descriptors :: proc(app: ^Vulkan_App, frame: ^Frame_Context) {
	update_descriptor_set(app, frame, frame.descriptor_set, &frame.cell_buffer)
	if frame.osd_descriptor_set != 0 do update_descriptor_set(app, frame, frame.osd_descriptor_set, &frame.osd_cell_buffer)
	update_selection_descriptor_set(app, frame)
}

ensure_visual_buffer :: proc(app: ^Vulkan_App, frame: ^Frame_Context) -> bool {
	required := len(app.demo.resources.visuals.records)
	if required <= frame.visual_capacity {
		return false
	}
	capacity := max(256, frame.visual_capacity)
	for capacity < required {
		capacity *= 2
	}
	if frame.visual_buffer.handle != 0 {
		destroy_buffer(app.device, &frame.visual_buffer)
	}
	frame.visual_capacity = capacity
	frame.visuals_uploaded = 0
	frame.visual_buffer = create_buffer(
		app,
		vk.DeviceSize(capacity * size_of(Gpu_Visual_Record)),
		{.STORAGE_BUFFER},
		{.HOST_VISIBLE, .HOST_COHERENT},
		true,
	)
	if frame.descriptor_set != 0 {
		update_text_descriptors(app, frame)
	}
	return true
}

ensure_cell_buffer :: proc(app: ^Vulkan_App, frame: ^Frame_Context) -> bool {
	required := len(app.demo.grid.cells)
	if required <= frame.cell_capacity do return false
	capacity := max(GRID_CELL_COUNT, frame.cell_capacity)
	for capacity < required do capacity *= 2
	if frame.cell_buffer.handle != 0 {
		destroy_buffer(app.device, &frame.cell_buffer)
	}
	frame.cell_capacity = capacity
	frame.cell_buffer = create_buffer(
		app,
		vk.DeviceSize(capacity * size_of(Gpu_Cell)),
		{.STORAGE_BUFFER},
		{.HOST_VISIBLE, .HOST_COHERENT},
		true,
	)
	if frame.descriptor_set != 0 do update_text_descriptors(app, frame)
	return true
}

ensure_decoration_buffer :: proc(app: ^Vulkan_App, frame: ^Frame_Context) -> bool {
	required := max(1, len(app.demo.grid.decorations))
	if required <= frame.decoration_capacity do return false
	capacity := max(GRID_CELL_COUNT, frame.decoration_capacity)
	for capacity < required do capacity *= 2
	if frame.decoration_buffer.handle != 0 {
		destroy_buffer(app.device, &frame.decoration_buffer)
	}
	frame.decoration_capacity = capacity
	frame.decoration_buffer = create_buffer(
		app,
		vk.DeviceSize(capacity * size_of(u32)),
		{.STORAGE_BUFFER},
		{.HOST_VISIBLE, .HOST_COHERENT},
		true,
	)
	if frame.descriptor_set != 0 do update_text_descriptors(app, frame)
	return true
}

ensure_osd_cell_buffer :: proc(app: ^Vulkan_App, frame: ^Frame_Context) -> bool {
	required := max(1, len(app.osd.cells))
	if required <= frame.osd_cell_capacity do return false
	capacity := max(512, frame.osd_cell_capacity)
	for capacity < required do capacity *= 2
	if frame.osd_cell_buffer.handle != 0 {
		destroy_buffer(app.device, &frame.osd_cell_buffer)
	}
	frame.osd_cell_capacity = capacity
	frame.osd_cell_buffer = create_buffer(app, vk.DeviceSize(capacity * size_of(Gpu_Cell)), {.STORAGE_BUFFER}, {.HOST_VISIBLE, .HOST_COHERENT}, true)
	if frame.osd_descriptor_set != 0 do update_text_descriptors(app, frame)
	return true
}

ensure_selection_mask_buffer :: proc(app: ^Vulkan_App, frame: ^Frame_Context) -> bool {
	required := max(1, len(app.selection.mask))
	if required <= frame.selection_mask_capacity do return false
	capacity := max(256, frame.selection_mask_capacity)
	for capacity < required do capacity *= 2
	if frame.selection_mask_buffer.handle != 0 {
		destroy_buffer(app.device, &frame.selection_mask_buffer)
	}
	frame.selection_mask_capacity = capacity
	frame.selection_mask_buffer = create_buffer(
		app,
		vk.DeviceSize(capacity * size_of(u32)),
		{.STORAGE_BUFFER},
		{.HOST_VISIBLE, .HOST_COHERENT},
		true,
	)
	if frame.selection_descriptor_set != 0 do update_selection_descriptor_set(app, frame)
	return true
}

ensure_staging_buffer :: proc(app: ^Vulkan_App, required_size: int) {
	if required_size <= int(app.staging_buffer.size) {
		return
	}
	capacity := max(4096, int(app.staging_buffer.size))
	for capacity < required_size {
		capacity *= 2
	}
	if app.staging_buffer.handle != 0 {
		destroy_buffer(app.device, &app.staging_buffer)
	}
	app.staging_buffer = create_buffer(
		app,
		vk.DeviceSize(capacity),
		{.TRANSFER_SRC},
		{.HOST_VISIBLE, .HOST_COHERENT},
		true,
	)
}

begin_one_time_commands :: proc(app: ^Vulkan_App) {
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

end_one_time_commands :: proc(app: ^Vulkan_App) {
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

upload_texture_resource :: proc(app: ^Vulkan_App, resource: ^Texture_Resource) -> bool {
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

sync_texture_resources :: proc(app: ^Vulkan_App, frame: ^Frame_Context) {
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

flush_text_resources :: proc(app: ^Vulkan_App, frame: ^Frame_Context) -> Gpu_Upload_Stats {
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

create_text_resources :: proc(app: ^Vulkan_App) {
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

create_synchronization :: proc(app: ^Vulkan_App) {
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
	create_swapchain_image_synchronization(app)
}

create_swapchain_image_synchronization :: proc(app: ^Vulkan_App) {
	semaphore_info := vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}
	app.render_finished = make([]vk.Semaphore, len(app.swapchain_images))
	for &semaphore in app.render_finished {
		vk_must(
			vk.CreateSemaphore(app.device, &semaphore_info, nil, &semaphore),
			"creating a render-finished semaphore",
		)
	}
	delete(app.images_in_flight)
	app.images_in_flight = make([]vk.Fence, len(app.swapchain_images))
	app.active_frame_count = min(len(app.frames), len(app.swapchain_images))
	app.frame_index %= app.active_frame_count
}

read_gpu_draw_time :: proc(app: ^Vulkan_App, frame: ^Frame_Context) -> (f64, bool) {
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

draw_frame :: proc(
	app: ^Vulkan_App,
	cursor_opacity: u16,
	read_back_framebuffer := false,
	text_opacity := max(u16),
	scroll_indicator_opacity := u16(0),
) -> Benchmark_Frame_Sample {
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
			recreate_swapchain(app)
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
	capture_frame := read_back_framebuffer || write_capture
	record_command_buffer(
		app,
		frame,
		image_index,
		cursor_opacity,
		text_opacity,
		scroll_indicator_opacity,
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
			recreate_swapchain(app)
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

record_frame_capture :: proc(app: ^Vulkan_App, command_buffer: vk.CommandBuffer, image_index: u32) {
	to_transfer := vk.ImageMemoryBarrier {
		sType = .IMAGE_MEMORY_BARRIER,
		srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
		dstAccessMask = {.TRANSFER_READ},
		oldLayout = .PRESENT_SRC_KHR,
		newLayout = .TRANSFER_SRC_OPTIMAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = app.swapchain_images[image_index],
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	vk.CmdPipelineBarrier(
		command_buffer,
		{.COLOR_ATTACHMENT_OUTPUT},
		{.TRANSFER},
		{},
		0,
		nil,
		0,
		nil,
		1,
		&to_transfer,
	)

	copy_region := vk.BufferImageCopy {
		imageSubresource = {aspectMask = {.COLOR}, layerCount = 1},
		imageExtent = {width = app.extent.width, height = app.extent.height, depth = 1},
	}
	vk.CmdCopyImageToBuffer(
		command_buffer,
		app.swapchain_images[image_index],
		.TRANSFER_SRC_OPTIMAL,
		app.capture_buffer.handle,
		1,
		&copy_region,
	)

	to_host := vk.BufferMemoryBarrier {
		sType               = .BUFFER_MEMORY_BARRIER,
		srcAccessMask       = {.TRANSFER_WRITE},
		dstAccessMask       = {.HOST_READ},
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		buffer              = app.capture_buffer.handle,
		size                = app.capture_buffer.size,
	}
	vk.CmdPipelineBarrier(
		command_buffer,
		{.TRANSFER},
		{.HOST},
		{},
		0,
		nil,
		1,
		&to_host,
		0,
		nil,
	)

	to_present := vk.ImageMemoryBarrier {
		sType = .IMAGE_MEMORY_BARRIER,
		srcAccessMask = {.TRANSFER_READ},
		oldLayout = .TRANSFER_SRC_OPTIMAL,
		newLayout = .PRESENT_SRC_KHR,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = app.swapchain_images[image_index],
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	vk.CmdPipelineBarrier(
		command_buffer,
		{.TRANSFER},
		{.BOTTOM_OF_PIPE},
		{},
		0,
		nil,
		0,
		nil,
		1,
		&to_present,
	)
}

record_padding_glow_source :: proc(
	app: ^Vulkan_App,
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
	app: ^Vulkan_App,
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
				frame.padding_glow_source_framebuffer,
			)
		record_padding_glow_source(
			app,
			frame,
			command_buffer,
			text_area,
				app.padding_glow_background_pipeline,
				frame.padding_glow_background_framebuffer,
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
				style = {PADDING_CLEAR_COLOUR, 0, 0, 0},
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

fixed_byte_string :: proc(bytes: ^[$N]byte) -> string {
	return strings.truncate_to_byte(string(bytes[:]), 0)
}

vk_must :: proc(result: vk.Result, operation: string, location := #caller_location) {
	if result != .SUCCESS {
		fmt.panicf("Vulkan failed while %s: %v", operation, result, loc = location)
	}
}
