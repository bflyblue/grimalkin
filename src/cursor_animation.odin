package main

import "core:math"

Cursor_Animation_Policy :: enum u8 {
	Blink,
	Pulse,
	Steady,
}

CURSOR_ANIMATION_POLICY :: Cursor_Animation_Policy.Pulse
CURSOR_ANIMATION_PERIOD :: 1.0
CURSOR_PULSE_SAMPLE_INTERVAL :: CURSOR_ANIMATION_PERIOD / 60.0
CURSOR_BLINK_SAMPLE_INTERVAL :: CURSOR_ANIMATION_PERIOD / 2.0
CURSOR_BASE_OPACITY :: 0.72
CURSOR_PULSE_MINIMUM_ENVELOPE :: 0.25

CURSOR_STYLE_MASK :: u32(0xff)
CURSOR_VISIBLE_BIT :: u32(1 << 8)
CURSOR_OPACITY_SHIFT :: 16
CURSOR_OPACITY_MASK :: u32(0xffff << CURSOR_OPACITY_SHIFT)

Cursor_Animation_State :: struct {
	epoch:          f64,
	next_sample_at: f64,
}

Cursor_Animation_Input :: struct {
	visible:   bool,
	blinking:  bool,
	text_blinking: bool,
	focused:   bool,
	minimized: bool,
}

Cursor_Animation_Sample :: struct {
	opacity:        u16,
	text_opacity:   u16,
	animated:       bool,
	next_sample_at: f64,
}

cursor_quantize_opacity :: proc(opacity: f64) -> u16 {
	scaled := math.round(clamp(opacity, 0.0, 1.0) * f64(max(u16)))
	return u16(scaled)
}

cursor_opacity_from_u16 :: proc(opacity: u16) -> f64 {
	return f64(opacity) / f64(max(u16))
}

cursor_next_sample_deadline :: proc(epoch, now, interval: f64) -> f64 {
	elapsed := max(0.0, now - epoch)
	step := math.floor(elapsed / interval) + 1.0
	deadline := epoch + step * interval
	if deadline <= now {
		deadline = now + interval
	}
	return deadline
}

cursor_animation_sample :: proc(
	policy: Cursor_Animation_Policy,
	input: Cursor_Animation_Input,
	epoch, now: f64,
) -> Cursor_Animation_Sample {
	base_opacity := cursor_quantize_opacity(CURSOR_BASE_OPACITY)
	full_opacity := max(u16)
	if !input.visible && !input.text_blinking {
		return {}
	}
	if !input.focused || input.minimized || policy == .Steady {
		return {
			opacity = base_opacity if input.visible else 0,
			text_opacity = full_opacity,
		}
	}

	elapsed := max(0.0, now - epoch)
	#partial switch policy {
	case .Blink:
		phase := elapsed - math.floor(elapsed / CURSOR_ANIMATION_PERIOD) * CURSOR_ANIMATION_PERIOD
		on := phase < CURSOR_BLINK_SAMPLE_INTERVAL
		animated := (input.visible && input.blinking) || input.text_blinking
		if !animated {
			return {opacity = base_opacity, text_opacity = full_opacity}
		}
		return {
			opacity = (base_opacity if on else 0) if input.visible && input.blinking else (base_opacity if input.visible else 0),
			text_opacity = full_opacity if on || !input.text_blinking else 0,
			animated = true,
			next_sample_at = cursor_next_sample_deadline(
				epoch,
				now,
				CURSOR_BLINK_SAMPLE_INTERVAL,
			),
		}
	case .Pulse:
		wave := 0.5 + 0.5 * math.cos(math.TAU * elapsed / CURSOR_ANIMATION_PERIOD)
		envelope := CURSOR_PULSE_MINIMUM_ENVELOPE +
			(1.0 - CURSOR_PULSE_MINIMUM_ENVELOPE) * wave
		return {
			opacity = cursor_quantize_opacity(CURSOR_BASE_OPACITY * envelope) if input.visible else 0,
			text_opacity = cursor_quantize_opacity(envelope) if input.text_blinking else full_opacity,
			animated = true,
			next_sample_at = cursor_next_sample_deadline(
				epoch,
				now,
				CURSOR_PULSE_SAMPLE_INTERVAL,
			),
		}
	case .Steady:
		return {
			opacity = base_opacity if input.visible else 0,
			text_opacity = full_opacity,
		}
	}
	return {
		opacity = base_opacity if input.visible else 0,
		text_opacity = full_opacity,
	}
}

cursor_animation_restart :: proc(
	state: ^Cursor_Animation_State,
	policy: Cursor_Animation_Policy,
	input: Cursor_Animation_Input,
	now: f64,
) -> Cursor_Animation_Sample {
	state.epoch = now
	sample := cursor_animation_sample(policy, input, state.epoch, now)
	state.next_sample_at = sample.next_sample_at
	return sample
}

cursor_pack_push_word :: proc(
	style: Terminal_Cursor_Style,
	visible: bool,
	opacity: u16,
) -> u32 {
	word := u32(style) & CURSOR_STYLE_MASK
	if visible do word |= CURSOR_VISIBLE_BIT
	word |= u32(opacity) << CURSOR_OPACITY_SHIFT
	return word
}

cursor_push_opacity :: proc(word: u32) -> u16 {
	return u16((word & CURSOR_OPACITY_MASK) >> CURSOR_OPACITY_SHIFT)
}
