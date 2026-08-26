package main

import "core:testing"

@(test)
wheel_scroll_accumulates_fractional_input_and_emits_multiple_rows :: proc(t: ^testing.T) {
	remainder := f64(0)
	first := wheel_scroll_update(&remainder, 0, 0.4, false, false, false)
	testing.expect_value(t, first.route, Wheel_Scroll_Route.History)
	testing.expect_value(t, first.history_rows, i64(0))
	testing.expect_value(t, remainder, f64(0.4))
	second := wheel_scroll_update(&remainder, 0, 2.8, false, false, false)
	testing.expect_value(t, second.history_rows, i64(-3))
	testing.expect(t, abs(remainder - 0.2) < 0.000_001)
}

@(test)
wheel_scroll_reversal_preserves_the_signed_fraction :: proc(t: ^testing.T) {
	remainder := f64(0)
	_ = wheel_scroll_update(&remainder, 0, 0.75, false, false, false)
	reversed := wheel_scroll_update(&remainder, 0, -1.5, false, false, false)
	testing.expect_value(t, reversed.history_rows, i64(0))
	testing.expect_value(t, remainder, f64(-0.75))
	completed := wheel_scroll_update(&remainder, 0, -0.5, false, false, false)
	testing.expect_value(t, completed.history_rows, i64(1))
	testing.expect_value(t, remainder, f64(-0.25))
}

@(test)
wheel_scroll_ignores_zero_and_horizontal_only_events :: proc(t: ^testing.T) {
	remainder := f64(0.5)
	update := wheel_scroll_update(&remainder, 3.0, 0, false, false, false)
	testing.expect_value(t, update.route, Wheel_Scroll_Route.Ignored)
	testing.expect_value(t, update.history_rows, i64(0))
	testing.expect_value(t, remainder, f64(0.5))
}

@(test)
wheel_scroll_routes_mouse_tracking_unless_shift_overrides_it :: proc(t: ^testing.T) {
	remainder := f64(0.5)
	application := wheel_scroll_update(&remainder, 0, 1, true, false, false)
	testing.expect_value(t, application.route, Wheel_Scroll_Route.Application)
	testing.expect_value(t, remainder, f64(0))
	history := wheel_scroll_update(&remainder, 0, 1, true, true, false)
	testing.expect_value(t, history.route, Wheel_Scroll_Route.History)
	testing.expect_value(t, history.history_rows, i64(-1))
}

@(test)
wheel_scroll_clears_remainder_when_input_is_suppressed :: proc(t: ^testing.T) {
	remainder := f64(-0.8)
	update := wheel_scroll_update(&remainder, 0, 0.1, false, false, true)
	testing.expect_value(t, update.route, Wheel_Scroll_Route.Suppressed)
	testing.expect_value(t, remainder, f64(0))
}

@(test)
wheel_scroll_is_a_clean_no_op_on_the_alternate_screen :: proc(t: ^testing.T) {
	remainder := f64(0.6)
	update := wheel_scroll_update(&remainder, 0, 0.6, false, false, false, false)
	testing.expect_value(t, update.route, Wheel_Scroll_Route.Suppressed)
	testing.expect_value(t, update.history_rows, i64(0))
	testing.expect_value(t, remainder, f64(0))

	// Mouse-aware alternate-screen applications still receive unmodified input.
	application := wheel_scroll_update(&remainder, 0, -1, true, false, false, false)
	testing.expect_value(t, application.route, Wheel_Scroll_Route.Application)
}
