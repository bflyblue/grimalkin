package main

import "core:testing"

@(test)
scrollback_compression_waits_for_idle_and_postpones_on_activity :: proc(t: ^testing.T) {
	scheduler := scrollback_compression_scheduler_init(true)
	scrollback_compression_observe(&scheduler, 7, 1.0)
	testing.expect_value(t, scheduler.next_step_at, max(f64))
	scrollback_compression_observe(&scheduler, 8, 2.0)
	testing.expect_value(t, scheduler.next_step_at, 2.25)
	testing.expect(t, !scrollback_compression_due(scheduler, 2.249))
	scrollback_compression_observe(&scheduler, 9, 2.1)
	testing.expect_value(t, scheduler.next_step_at, 2.35)
	testing.expect(t, scrollback_compression_due(scheduler, 2.35))
}

@(test)
scrollback_compression_pending_steps_are_spaced_and_completion_stops :: proc(t: ^testing.T) {
	scheduler := scrollback_compression_scheduler_init(true)
	scheduler.activity_known = true
	scheduler.next_step_at = 4.0
	scrollback_compression_step_finished(&scheduler, .Pending, 4.0)
	testing.expect_value(t, scheduler.next_step_at, 4.001)
	scrollback_compression_step_finished(&scheduler, .Complete, 4.001)
	testing.expect_value(t, scheduler.next_step_at, max(f64))
	testing.expect(t, scheduler.enabled)
}

@(test)
scrollback_compression_unsupported_or_disabled_has_no_deadline :: proc(t: ^testing.T) {
	scheduler := scrollback_compression_scheduler_init(true)
	scheduler.next_step_at = 3.0
	scrollback_compression_step_finished(&scheduler, .Unsupported, 3.0)
	testing.expect(t, !scheduler.enabled)
	testing.expect_value(t, scrollback_compression_wait_deadline(scheduler), max(f64))
	disabled := scrollback_compression_scheduler_init(false)
	scrollback_compression_observe(&disabled, 10, 1.0)
	testing.expect(t, !disabled.activity_known)
}

@(test)
scrollback_compression_deadline_is_available_to_minimized_waits :: proc(t: ^testing.T) {
	// The minimized and normal branches both call this helper before waiting;
	// an idle step therefore wakes a minimized window without requiring input.
	scheduler := scrollback_compression_scheduler_init(true)
	scheduler.next_step_at = 8.25
	testing.expect_value(t, scrollback_compression_wait_deadline(scheduler), 8.25)
	testing.expect_value(t, scrollback_compression_wait_deadline(scheduler, 9.0), 8.25)
	testing.expect_value(t, scrollback_compression_wait_deadline(scheduler, 7.0), 7.0)
}
