package main

import "core:testing"

cursor_animation_test_input :: proc(
	visible := true,
	blinking := true,
	text_blinking := false,
	focused := true,
	minimized := false,
) -> Cursor_Animation_Input {
	return {
		visible = visible,
		blinking = blinking,
		text_blinking = text_blinking,
		focused = focused,
		minimized = minimized,
	}
}

@(test)
blinking_text_uses_the_cursor_policy_phase_without_changing_cursor_semantics :: proc(t: ^testing.T) {
	blink_input := cursor_animation_test_input(
		visible = true,
		blinking = false,
		text_blinking = true,
	)
	blink_off := cursor_animation_sample(.Blink, blink_input, 10.0, 10.5)
	testing.expect_value(t, blink_off.opacity, cursor_quantize_opacity(CURSOR_BASE_OPACITY))
	testing.expect_value(t, blink_off.text_opacity, u16(0))
	testing.expect(t, blink_off.animated)

	pulse_input := cursor_animation_test_input(visible = false, text_blinking = true)
	pulse_peak := cursor_animation_sample(.Pulse, pulse_input, 10.0, 10.0)
	pulse_trough := cursor_animation_sample(.Pulse, pulse_input, 10.0, 10.5)
	testing.expect_value(t, pulse_peak.opacity, u16(0))
	cursor_expect_opacity_near(t, pulse_peak.text_opacity, 1.0)
	cursor_expect_opacity_near(t, pulse_trough.text_opacity, CURSOR_PULSE_MINIMUM_ENVELOPE)
	testing.expect(t, pulse_trough.animated)

	steady := cursor_animation_sample(.Steady, pulse_input, 10.0, 10.5)
	testing.expect_value(t, steady.text_opacity, max(u16))
	testing.expect(t, !steady.animated)
}

cursor_expect_opacity_near :: proc(t: ^testing.T, actual: u16, expected: f64) {
	difference := abs(cursor_opacity_from_u16(actual) - expected)
	testing.expect(t, difference <= 1.0 / f64(max(u16)))
}

@(test)
cursor_pulse_uses_elapsed_monotonic_phase :: proc(t: ^testing.T) {
	input := cursor_animation_test_input()
	peak := cursor_animation_sample(.Pulse, input, 10.0, 10.0)
	trough := cursor_animation_sample(.Pulse, input, 10.0, 10.5)
	wrapped := cursor_animation_sample(.Pulse, input, 10.0, 11.0)
	late := cursor_animation_sample(.Pulse, input, 10.0, 12.25)
	reference := cursor_animation_sample(.Pulse, input, 10.0, 10.25)

	cursor_expect_opacity_near(t, peak.opacity, CURSOR_BASE_OPACITY)
	cursor_expect_opacity_near(
		t,
		trough.opacity,
		CURSOR_BASE_OPACITY * CURSOR_PULSE_MINIMUM_ENVELOPE,
	)
	testing.expect_value(t, wrapped.opacity, peak.opacity)
	testing.expect_value(t, late.opacity, reference.opacity)
	testing.expect(t, late.animated)
	testing.expect(t, late.next_sample_at > 12.25)
	testing.expect(t, late.next_sample_at <= 12.25 + CURSOR_PULSE_SAMPLE_INTERVAL + 0.000001)
}

@(test)
cursor_blink_uses_half_period_boundaries_without_catch_up :: proc(t: ^testing.T) {
	input := cursor_animation_test_input()
	on := cursor_animation_sample(.Blink, input, 3.0, 3.499999)
	off := cursor_animation_sample(.Blink, input, 3.0, 3.5)
	wrapped := cursor_animation_sample(.Blink, input, 3.0, 4.0)
	late := cursor_animation_sample(.Blink, input, 3.0, 8.75)

	cursor_expect_opacity_near(t, on.opacity, CURSOR_BASE_OPACITY)
	testing.expect_value(t, off.opacity, u16(0))
	testing.expect_value(t, wrapped.opacity, on.opacity)
	testing.expect_value(t, late.opacity, u16(0))
	testing.expect_value(t, late.next_sample_at, 9.0)
}

@(test)
cursor_semantics_gate_animation_and_keep_a_steady_cursor :: proc(t: ^testing.T) {
	base := cursor_quantize_opacity(CURSOR_BASE_OPACITY)
	steady := cursor_animation_sample(.Steady, cursor_animation_test_input(), 0, 0.5)
	non_blinking_pulse := cursor_animation_sample(
		.Pulse,
		cursor_animation_test_input(blinking = false),
		0,
		0.5,
	)
	non_blinking_blink := cursor_animation_sample(
		.Blink,
		cursor_animation_test_input(blinking = false),
		0,
		0.5,
	)
	unfocused := cursor_animation_sample(
		.Pulse,
		cursor_animation_test_input(focused = false),
		0,
		0.5,
	)
	minimized := cursor_animation_sample(
		.Pulse,
		cursor_animation_test_input(minimized = true),
		0,
		0.5,
	)
	hidden := cursor_animation_sample(
		.Pulse,
		cursor_animation_test_input(visible = false),
		0,
		0.5,
	)

	samples := [?]Cursor_Animation_Sample{steady, non_blinking_blink, unfocused, minimized}
	for sample in samples {
		testing.expect_value(t, sample.opacity, base)
		testing.expect(t, !sample.animated)
		testing.expect_value(t, sample.next_sample_at, f64(0))
	}
	testing.expect(t, non_blinking_pulse.animated)
	cursor_expect_opacity_near(
		t,
		non_blinking_pulse.opacity,
		CURSOR_BASE_OPACITY * CURSOR_PULSE_MINIMUM_ENVELOPE,
	)
	testing.expect_value(t, hidden.opacity, u16(0))
	testing.expect(t, !hidden.animated)
}

@(test)
cursor_reset_epoch_starts_at_peak_and_deadlines_skip_late_samples :: proc(t: ^testing.T) {
	input := cursor_animation_test_input()
	state := Cursor_Animation_State{epoch = 1.0, next_sample_at = 2.0}
	reset := cursor_animation_restart(&state, .Pulse, input, 42.0)
	late_deadline := cursor_next_sample_deadline(42.0, 44.4, CURSOR_PULSE_SAMPLE_INTERVAL)

	testing.expect_value(t, state.epoch, 42.0)
	cursor_expect_opacity_near(t, reset.opacity, CURSOR_BASE_OPACITY)
	testing.expect(t, reset.next_sample_at > 42.0)
	testing.expect_value(t, state.next_sample_at, reset.next_sample_at)
	testing.expect(t, late_deadline > 44.4)
	testing.expect(t, late_deadline <= 44.4 + CURSOR_PULSE_SAMPLE_INTERVAL + 0.000001)
}

@(test)
cursor_restoration_restarts_animation_from_a_visible_peak :: proc(t: ^testing.T) {
	state := Cursor_Animation_State{}
	minimized := cursor_animation_restart(
		&state,
		.Pulse,
		cursor_animation_test_input(minimized = true),
		6.0,
	)
	restored := cursor_animation_restart(
		&state,
		.Pulse,
		cursor_animation_test_input(),
		7.0,
	)

	testing.expect(t, !minimized.animated)
	cursor_expect_opacity_near(t, minimized.opacity, CURSOR_BASE_OPACITY)
	testing.expect_value(t, state.epoch, 7.0)
	testing.expect(t, restored.animated)
	cursor_expect_opacity_near(t, restored.opacity, CURSOR_BASE_OPACITY)
	testing.expect(t, restored.next_sample_at > 7.0)
}

@(test)
cursor_push_word_preserves_shape_visibility_and_sixteen_bit_opacity :: proc(t: ^testing.T) {
	opacity := u16(0xa55a)
	word := cursor_pack_push_word(.Hollow_Block, true, opacity)

	testing.expect_value(t, word & CURSOR_STYLE_MASK, u32(Terminal_Cursor_Style.Hollow_Block))
	testing.expect(t, (word & CURSOR_VISIBLE_BIT) != 0)
	testing.expect_value(t, word & u32(0x0000fe00), u32(0))
	testing.expect_value(t, cursor_push_opacity(word), opacity)
	testing.expect_value(
		t,
		cursor_push_opacity(cursor_pack_push_word(.Bar, false, max(u16))),
		max(u16),
	)
}
