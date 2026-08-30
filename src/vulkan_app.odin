package main

import c "core:c"
import "vendor:glfw"
import vk "vendor:vulkan"

when ODIN_OS == .Windows {
	foreign import png_shim {"system:grimalkin_png.obj", "system:libpng16.lib"}
} else {
	foreign import png_shim {"system:grimalkin_png", "system:png16"}
}

// Allocation hooks and decoder signature mirroring src/png_shim.h. The Kitty
// graphics decoder is registered with the libghostty-vt shim from Odin so that
// libpng stays inside the PNG shim.
Png_Allocate_Proc :: #type proc "c" (allocator_context: rawptr, len: c.size_t) -> [^]u8
Png_Release_Proc :: #type proc "c" (allocator_context: rawptr, pixels: [^]u8, len: c.size_t)
Png_Decode_Proc :: #type proc "c" (
	data: [^]u8,
	len: c.size_t,
	allocate: Png_Allocate_Proc,
	release: Png_Release_Proc,
	allocator_context: rawptr,
	out_width: ^u32,
	out_height: ^u32,
	out_pixels: ^[^]u8,
	out_len: ^c.size_t,
) -> c.int

@(default_calling_convention = "c")
foreign png_shim {
	grimalkin_write_png_rgba :: proc(path: cstring, width, height: u32, pixels: [^]u8, stride: c.size_t) -> c.int ---
	grimalkin_decode_png_rgba :: proc(
		data: [^]u8,
		len: c.size_t,
		allocate: Png_Allocate_Proc,
		release: Png_Release_Proc,
		allocator_context: rawptr,
		out_width: ^u32,
		out_height: ^u32,
		out_pixels: ^[^]u8,
		out_len: ^c.size_t,
	) -> c.int ---
}

ENABLE_VALIDATION :: #config(ENABLE_VALIDATION, ODIN_DEBUG)
DEMO_FRAME_LIMIT :: #config(DEMO_FRAME_LIMIT, 0)
BENCHMARK_MODE :: #config(BENCHMARK_MODE, false)
BENCHMARK_WARMUP_FRAMES :: #config(BENCHMARK_WARMUP_FRAMES, 60)
BENCHMARK_SAMPLE_FRAMES :: #config(BENCHMARK_SAMPLE_FRAMES, 300)
MAX_TEXTURE_RESOURCES_CAP :: u32(1024)
MAX_FRAMES_IN_FLIGHT :: 3
// Glow subtracts background from full terminal colour. A linear float
// intermediate preserves faint residuals that an 8-bit target would quantize
// away before the final output encoding and dither.
PADDING_GLOW_SOURCE_FORMAT :: vk.Format.R16G16B16A16_SFLOAT

#assert(BENCHMARK_WARMUP_FRAMES >= 0)
#assert(BENCHMARK_SAMPLE_FRAMES > 0)

FULLSCREEN_VERTEX_SHADER :: #load("shaders/fullscreen.vert.spv")
FRAGMENT_SHADER :: #load("shaders/text.frag.spv")
IMAGE_QUAD_FRAGMENT_SHADER :: #load("shaders/image_quad.frag.spv")
OSD_FRAGMENT_SHADER :: #load("shaders/osd.frag.spv")
PADDING_GLOW_FRAGMENT_SHADER :: #load("shaders/padding_glow.frag.spv")
PADDING_GLOW_BACKGROUND_FRAGMENT_SHADER :: #load("shaders/padding_glow_background.frag.spv")
SCROLL_INDICATOR_FRAGMENT_SHADER :: #load("shaders/scroll_indicator.frag.spv")
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

Offscreen_Target :: struct {
	image:           vk.Image,
	memory:          vk.DeviceMemory,
	sampled_view:    vk.ImageView,
	attachment_view: vk.ImageView,
	framebuffer:     vk.Framebuffer,
}

Frame_Context :: struct {
	descriptor_set:       vk.DescriptorSet,
	osd_descriptor_set:   vk.DescriptorSet,
	selection_descriptor_set: vk.DescriptorSet,
	padding_glow_descriptor_set: vk.DescriptorSet,
	padding_glow_source: Offscreen_Target,
	padding_glow_background: Offscreen_Target,
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
	image_placement_buffer: Gpu_Buffer,
	image_placement_capacity: int,
	image_placement_descriptor_set: vk.DescriptorSet,
	image_placement_generation: u64,
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

Gpu_Device_Candidate :: struct {
	device:             vk.PhysicalDevice,
	properties:         vk.PhysicalDeviceProperties,
	queue_families:     Queue_Families,
	enumeration_index:  int,
}

Gpu_Selection_Status :: struct {
	active_name:          string,
	active_type:          vk.PhysicalDeviceType,
	suitable_count:       int,
	integrated_available: bool,
	discrete_available:   bool,
	fallback_active:      bool,
}

Swapchain_Support :: struct {
	capabilities:  vk.SurfaceCapabilitiesKHR,
	formats:       []vk.SurfaceFormatKHR,
	present_modes: []vk.PresentModeKHR,
}

Vulkan_Device_Resources :: struct {
	instance:           vk.Instance,
	debug_messenger:    vk.DebugUtilsMessengerEXT,
	surface:            vk.SurfaceKHR,
	physical_device:    vk.PhysicalDevice,
	texture_capacity:   u32,
	device:             vk.Device,
	graphics_queue:     vk.Queue,
	present_queue:      vk.Queue,
	queue_families:     Queue_Families,
	padding_glow_descriptor_layout: vk.DescriptorSetLayout,
	descriptor_layout:  vk.DescriptorSetLayout,
	image_placement_descriptor_layout: vk.DescriptorSetLayout,
	descriptor_pool:    vk.DescriptorPool,
	staging_buffer:     Gpu_Buffer,
	texture_images:     [dynamic]Gpu_Texture_Image,
	command_pool:       vk.CommandPool,
	command_buffer:     vk.CommandBuffer, // synchronous texture upload command buffer
	upload_fence:       vk.Fence,
	frames:             []Frame_Context,
	timestamp_period:   f64,
	timestamp_bits:     u32,
}

Vulkan_Swapchain_Resources :: struct {
	swapchain:          vk.SwapchainKHR,
	// Set instead of the swapchain when rendering headless. The target still
	// publishes itself through swapchain_images and image_views below.
	headless_image:     vk.Image,
	headless_memory:    vk.DeviceMemory,
	swapchain_images:   []vk.Image,
	image_views:        []vk.ImageView,
	surface_format:     vk.SurfaceFormatKHR,
	manual_srgb_output: bool,
	// The cell size most recently handed to the terminal, so a resize is not
	// skipped when only the cell size changed.
	terminal_cell_width:  u32,
	terminal_cell_height: u32,
	extent:             vk.Extent2D,
	render_pass:        vk.RenderPass,
	text_pipeline:      Fullscreen_Pipeline,
	osd_pipeline:       Fullscreen_Pipeline,
	padding_glow_pipeline: Fullscreen_Pipeline,
	padding_glow_source_render_pass: vk.RenderPass,
	padding_glow_source_pipeline: Fullscreen_Pipeline,
	padding_glow_background_pipeline: Fullscreen_Pipeline,
	padding_glow_descriptor_pool: vk.DescriptorPool,
	padding_glow_sampler: vk.Sampler,
	scroll_indicator_pipeline: Fullscreen_Pipeline,
	selection_pipeline: Fullscreen_Pipeline,
	image_quad_pipeline: Fullscreen_Pipeline,
	framebuffers:       []vk.Framebuffer,
	active_frame_count: int,
	render_finished:    []vk.Semaphore,
	images_in_flight:   []vk.Fence,
	capture_buffer:     Gpu_Buffer,
}

Vulkan_Renderer :: struct {
	using device_resources:    Vulkan_Device_Resources,
	using swapchain_resources: Vulkan_Swapchain_Resources,
	frame_index:     int,
	grid_generation: u64,
	osd_generation:  u64,
}

Application_Capture_State :: struct {
	capture_path:       string,
	capture_complete:   bool,
	capture_deadline:   f64,
	capture_exit:       bool,
	framebuffer_readback: bool,
}

Application_Settings_State :: struct {
	settings:           Application_Settings,
	applied_settings:   Application_Settings,
	font_catalog:       ^Font_Catalog,
	active_font_index:  int,
	settings_path:      string,
	settings_save_pending: bool,
	settings_save_deadline: f64,
	settings_colour_theme_refresh_pending: bool,
	settings_font_rebuild_pending: bool,
	settings_layout_pending: bool,
	gpu_rebuild_pending: bool,
	gpu_selection:       Gpu_Selection_Status,
	detected_display_rotation: Display_Rotation,
	display_rotation_check_pending: bool,
	display_rotation_check_deadline: f64,
	content_scale_x:    f32,
	content_scale_y:    f32,
}

Application_Input_State :: struct {
	pending_key:        i32,
	pending_scancode:   i32,
	pending_action:     i32,
	pending_mods:       i32,
	pending_valid:      bool,
	hotkey_suppressed:  u8,
	font_size_shortcut: Font_Size_Shortcut_State,
	selection:          Terminal_Selection,
	clipboard_insert_suppressed: bool,
	paste_confirmation_suppressed_key: i32,
	mouse_buttons:      u16,
	scroll_remainder:   f64,
	selection_text_cursor:  glfw.CursorHandle,
	selection_block_cursor: glfw.CursorHandle,
	url_hover:              Url_Hover,
	url_hover_cursor:       glfw.CursorHandle,
}

Application_Paste_State :: struct {
	pending_paste:      []u8,
	paste_confirmation: bool,
}

Window_Geometry :: struct {
	x, y:          i32,
	width, height: i32,
}

Fullscreen_Window_State :: struct {
	active:            bool,
	restore_geometry:  Window_Geometry,
	restore_maximized: bool,
}

Application_Window_State :: struct {
	fullscreen:              Fullscreen_Window_State,
	windowed_geometry:       Window_Geometry,
	windowed_geometry_valid: bool,
}

Grimalkin_App :: struct {
	demo:   ^Grimalkin_Demo,
	window: glfw.WindowHandle,
	using renderer:       Vulkan_Renderer,
	using capture:        Application_Capture_State,
	using settings_state: Application_Settings_State,
	using input:          Application_Input_State,
	using paste:          Application_Paste_State,
	using window_state:   Application_Window_State,
	cursor_gpu_test:   bool,
	// No surface, no swapchain, no display server. Implied by cursor_gpu_test,
	// which renders into an image it owns so it never waits on a compositor.
	headless:          bool,
	framebuffer_dirty: bool,
	minimized:         bool,
	redraw:            bool,
	focused:           bool,
	cursor_animation:  Cursor_Animation_State,
	scroll_indicator:  Scroll_Indicator_State,
	compression:       Scrollback_Compression_Scheduler,
	osd:               Osd_State,
}

Render_Frame_Input :: struct {
	cursor_opacity:           u16,
	read_back_framebuffer:    bool,
	text_opacity:             u16,
	scroll_indicator_opacity: u16,
}
