package main

import "vendor:glfw"
import vk "vendor:vulkan"

SCROLL_INDICATOR_WIDTH_LOGICAL :: f32(3)
SCROLL_INDICATOR_EDGE_GAP_LOGICAL :: f32(4)
SCROLL_INDICATOR_VERTICAL_GAP_LOGICAL :: f32(6)
SCROLL_INDICATOR_MINIMUM_HEIGHT_LOGICAL :: f32(24)
SCROLL_INDICATOR_HIT_WIDTH_LOGICAL :: f32(12)
SCROLL_INDICATOR_HOLD_SECONDS :: f64(1.0)
SCROLL_INDICATOR_FADE_SECONDS :: f64(0.25)
SCROLL_INDICATOR_FRAME_SECONDS :: f64(1.0 / 60.0)
SCROLL_INDICATOR_DETACHED_OPACITY :: f64(0.25)
SCROLL_INDICATOR_COLOUR :: u32(0xffa0a0a0)

Scroll_Indicator_State :: struct {
	revealed:       bool,
	revealed_at:    f64,
	next_sample_at: f64,
	hovered:        bool,
	dragging:       bool,
	drag_anchor_y:  f64,
}

Scroll_Indicator_Sample :: struct {
	opacity:       u16,
	animated:      bool,
	next_sample_at: f64,
}

Scroll_Indicator_Geometry :: struct {
	rect:           vk.Rect2D,
	hit_rect:       vk.Rect2D,
	track_y:        i32,
	travel:         u32,
	maximum_offset: u64,
	valid:          bool,
}

Scroll_Indicator_Mouse_Update :: enum u8 {
	Unhandled,
	Drag_Began,
	Drag_Ended,
}

Scroll_Indicator_Push :: struct {
	rect:  [4]i32, // x, y, width, height in framebuffer pixels
	style: [4]u32, // packed sRGB colour, opacity, manual sRGB output, reserved
}

#assert(size_of(Scroll_Indicator_Push) == 32)

scroll_indicator_reveal :: proc(state: ^Scroll_Indicator_State, now: f64) {
	state.revealed = true
	state.revealed_at = now
	state.next_sample_at = now
}

scroll_indicator_set_hovered :: proc(
	state: ^Scroll_Indicator_State,
	hovered: bool,
	now: f64,
) -> bool {
	if state.hovered == hovered do return false
	state.hovered = hovered
	scroll_indicator_reveal(state, now)
	return true
}

scroll_indicator_quantize_opacity :: proc(value: f64) -> u16 {
	return u16(clamp(value, 0, 1) * f64(max(u16)) + 0.5)
}

scroll_indicator_sample :: proc(
	state: ^Scroll_Indicator_State,
	now: f64,
	viewport_active: bool,
) -> Scroll_Indicator_Sample {
	if !state.revealed {
		state.next_sample_at = max(f64)
		return {next_sample_at = max(f64)}
	}
	if state.hovered || state.dragging {
		state.next_sample_at = max(f64)
		return {
			opacity        = max(u16),
			next_sample_at = max(f64),
		}
	}

	fade_start := state.revealed_at + SCROLL_INDICATOR_HOLD_SECONDS
	fade_end := fade_start + SCROLL_INDICATOR_FADE_SECONDS
	target := SCROLL_INDICATOR_DETACHED_OPACITY
	if viewport_active do target = 0

	if now < fade_start {
		state.next_sample_at = fade_start
		return {
			opacity        = max(u16),
			animated       = true,
			next_sample_at = fade_start,
		}
	}
	if now < fade_end {
		progress := clamp((now - fade_start) / SCROLL_INDICATOR_FADE_SECONDS, 0, 1)
		eased := progress * progress * (3 - 2 * progress)
		opacity := 1 + (target - 1) * eased
		next_sample := min(fade_end, now + SCROLL_INDICATOR_FRAME_SECONDS)
		state.next_sample_at = next_sample
		return {
			opacity        = scroll_indicator_quantize_opacity(opacity),
			animated       = true,
			next_sample_at = next_sample,
		}
	}

	state.next_sample_at = max(f64)
	return {
		opacity        = scroll_indicator_quantize_opacity(target),
		next_sample_at = max(f64),
	}
}

scroll_indicator_geometry :: proc(
	frame_extent: vk.Extent2D,
	text_area: vk.Rect2D,
	total_rows, offset_rows, visible_rows: u64,
	content_scale_x, content_scale_y: f32,
) -> Scroll_Indicator_Geometry {
	if frame_extent.width == 0 || text_area.extent.height == 0 ||
	   total_rows <= visible_rows || visible_rows == 0 {
		return {}
	}
	thickness := max(u32(1), u32(SCROLL_INDICATOR_WIDTH_LOGICAL * max(content_scale_x, 1) + 0.5))
	edge_gap := max(u32(1), u32(SCROLL_INDICATOR_EDGE_GAP_LOGICAL * max(content_scale_x, 1) + 0.5))
	vertical_gap := u32(SCROLL_INDICATOR_VERTICAL_GAP_LOGICAL * max(content_scale_y, 1) + 0.5)
	if frame_extent.width <= edge_gap do return {}
	if text_area.extent.height <= vertical_gap * 2 do return {}
	thickness = min(thickness, frame_extent.width - edge_gap)

	track_height := text_area.extent.height - vertical_gap * 2
	proportional_height := u32(f64(track_height) * f64(visible_rows) / f64(total_rows) + 0.5)
	minimum_height := max(
		u32(1),
		u32(SCROLL_INDICATOR_MINIMUM_HEIGHT_LOGICAL * max(content_scale_y, 1) + 0.5),
	)
	thumb_height := clamp(max(minimum_height, proportional_height), u32(1), track_height)
	maximum_offset := total_rows - visible_rows
	clamped_offset := min(offset_rows, maximum_offset)
	travel := track_height - thumb_height
	thumb_y := u32(0)
	if maximum_offset > 0 && travel > 0 {
		thumb_y = u32(f64(travel) * f64(clamped_offset) / f64(maximum_offset) + 0.5)
	}

	rect := vk.Rect2D {
		offset = {
			x = i32(frame_extent.width - edge_gap - thickness),
			y = text_area.offset.y + i32(vertical_gap + thumb_y),
		},
		extent = {width = thickness, height = thumb_height},
	}
	hit_width := max(
		thickness,
		u32(SCROLL_INDICATOR_HIT_WIDTH_LOGICAL * max(content_scale_x, 1) + 0.5),
	)
	hit_right := min(frame_extent.width, u32(rect.offset.x) + thickness + edge_gap)
	hit_left := u32(0)
	if hit_right > hit_width do hit_left = hit_right - hit_width

	return {
		rect = rect,
		hit_rect = {
			offset = {
				x = i32(hit_left),
				y = rect.offset.y,
			},
			extent = {width = hit_right - hit_left, height = thumb_height},
		},
		track_y = text_area.offset.y + i32(vertical_gap),
		travel = travel,
		maximum_offset = maximum_offset,
		valid = true,
	}
}

scroll_indicator_contains :: proc(
	geometry: Scroll_Indicator_Geometry,
	x, y: f64,
) -> bool {
	if !geometry.valid do return false
	left := f64(geometry.hit_rect.offset.x)
	top := f64(geometry.hit_rect.offset.y)
	right := left + f64(geometry.hit_rect.extent.width)
	bottom := top + f64(geometry.hit_rect.extent.height)
	return x >= left && x < right && y >= top && y < bottom
}

scroll_indicator_mouse_button_update :: proc(
	state: ^Scroll_Indicator_State,
	geometry: Scroll_Indicator_Geometry,
	action: i32,
	x, y, now: f64,
) -> Scroll_Indicator_Mouse_Update {
	if action == glfw.RELEASE && state.dragging {
		state.dragging = false
		state.hovered = scroll_indicator_contains(geometry, x, y)
		scroll_indicator_reveal(state, now)
		return .Drag_Ended
	}
	if action != glfw.PRESS || !scroll_indicator_contains(geometry, x, y) {
		return .Unhandled
	}
	state.dragging = true
	state.hovered = true
	state.drag_anchor_y = clamp(y - f64(geometry.rect.offset.y), 0, f64(geometry.rect.extent.height))
	scroll_indicator_reveal(state, now)
	return .Drag_Began
}

scroll_indicator_drag_target :: proc(
	geometry: Scroll_Indicator_Geometry,
	pointer_y, drag_anchor_y: f64,
) -> (u64, bool) {
	if !geometry.valid || geometry.travel == 0 || geometry.maximum_offset == 0 {
		return 0, false
	}
	thumb_y := pointer_y - drag_anchor_y
	position := clamp(thumb_y - f64(geometry.track_y), 0, f64(geometry.travel))
	target := u64(
		position * f64(geometry.maximum_offset) / f64(geometry.travel) + 0.5,
	)
	return min(target, geometry.maximum_offset), true
}

scroll_indicator_row_delta :: proc(current, target: u64) -> i64 {
	maximum := u64(max(i64))
	if target >= current do return i64(min(target - current, maximum))
	return -i64(min(current - target, maximum))
}

scroll_delta_for_key :: proc(
	key, action, mods: i32,
	viewport_rows: u16,
	total_rows: u64,
	page_modifier, line_modifier: Scroll_Modifier,
) -> (i64, bool) {
	semantic_mods := mods & (glfw.MOD_SHIFT | glfw.MOD_CONTROL | glfw.MOD_ALT | glfw.MOD_SUPER)
	page_mods, page_enabled := scroll_modifier_glfw_bits(page_modifier)
	line_mods, line_enabled := scroll_modifier_glfw_bits(line_modifier)
	page := page_enabled && semantic_mods == page_mods &&
		(key == glfw.KEY_PAGE_UP || key == glfw.KEY_PAGE_DOWN)
	extreme := page_enabled && semantic_mods == page_mods &&
		(key == glfw.KEY_HOME || key == glfw.KEY_END)
	line := line_enabled && semantic_mods == line_mods &&
		(key == glfw.KEY_UP || key == glfw.KEY_DOWN)
	if !page && !extreme && !line do return 0, false
	if action != glfw.PRESS && action != glfw.REPEAT do return 0, true
	delta := i64(1)
	if page do delta = i64(viewport_rows)
	if extreme do delta = i64(total_rows)
	if key == glfw.KEY_PAGE_UP || key == glfw.KEY_HOME || key == glfw.KEY_UP {
		delta = -delta
	}
	return delta, true
}

scroll_modifier_glfw_bits :: proc(value: Scroll_Modifier) -> (i32, bool) {
	switch value {
	case .Off:        return 0, false
	case .Shift:      return glfw.MOD_SHIFT, true
	case .Ctrl:       return glfw.MOD_CONTROL, true
	case .Ctrl_Shift: return glfw.MOD_CONTROL | glfw.MOD_SHIFT, true
	}
	return 0, false
}

terminal_input_returns_to_tail :: proc(
	action: i32,
	encoded_ok: bool,
	encoded_len: int,
	viewport_active: bool,
) -> bool {
	return action != glfw.RELEASE && encoded_ok && encoded_len > 0 && !viewport_active
}
