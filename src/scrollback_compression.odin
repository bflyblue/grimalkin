package main

import "vendor:glfw"

SCROLLBACK_COMPRESSION_IDLE_SECONDS :: 0.250
SCROLLBACK_COMPRESSION_STEP_SECONDS :: 0.001

Scrollback_Compression_Scheduler :: struct {
	enabled:        bool,
	activity_known: bool,
	activity:       u64,
	next_step_at:   f64,
}

scrollback_compression_scheduler_init :: proc(enabled: bool) -> Scrollback_Compression_Scheduler {
	return {
		enabled = enabled,
		next_step_at = max(f64),
	}
}

scrollback_compression_observe :: proc(
	scheduler: ^Scrollback_Compression_Scheduler,
	activity: u64,
	now: f64,
) {
	if !scheduler.enabled do return
	if !scheduler.activity_known {
		scheduler.activity_known = true
		scheduler.activity = activity
		return
	}
	if scheduler.activity != activity {
		scheduler.activity = activity
		scheduler.next_step_at = now + SCROLLBACK_COMPRESSION_IDLE_SECONDS
	}
}

scrollback_compression_due :: proc(
	scheduler: Scrollback_Compression_Scheduler,
	now: f64,
) -> bool {
	return scheduler.enabled && scheduler.next_step_at != max(f64) &&
		now >= scheduler.next_step_at
}

scrollback_compression_step_finished :: proc(
	scheduler: ^Scrollback_Compression_Scheduler,
	result: Terminal_Compression_Result,
	now: f64,
) {
	switch result {
	case .Pending:
		scheduler.next_step_at = now + SCROLLBACK_COMPRESSION_STEP_SECONDS
	case .Complete:
		scheduler.next_step_at = max(f64)
	case .Unsupported, .Error:
		scheduler.enabled = false
		scheduler.next_step_at = max(f64)
	}
}

scrollback_compression_wait_deadline :: proc(
	scheduler: Scrollback_Compression_Scheduler,
	current: f64 = max(f64),
) -> f64 {
	if !scheduler.enabled || scheduler.next_step_at == max(f64) do return current
	return min(current, scheduler.next_step_at)
}

scrollback_compression_capture_baseline :: proc(app: ^Grimalkin_App) {
	if app == nil || !app.compression.enabled do return
	activity, ok := terminal_core_compression_activity(&app.demo.terminal)
	if !ok {
		app.compression.enabled = false
		return
	}
	scrollback_compression_observe(&app.compression, activity, glfw.GetTime())
}

// This runs only from the GLFW thread, between the previous frame's terminal
// work and the next render. No Ghostty writes, snapshots, selection, search, or
// rendering can overlap an incremental step.
scrollback_compression_service :: proc(app: ^Grimalkin_App, now: f64) {
	if app == nil || !app.compression.enabled do return
	activity, ok := terminal_core_compression_activity(&app.demo.terminal)
	if !ok {
		app.compression.enabled = false
		app.compression.next_step_at = max(f64)
		return
	}
	scrollback_compression_observe(&app.compression, activity, now)
	if scrollback_compression_due(app.compression, now) {
		result := terminal_core_compress_incremental(&app.demo.terminal)
		scrollback_compression_step_finished(&app.compression, result, now)
	}
}
