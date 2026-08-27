package main

import "core:testing"

@(test)
terminal_session_drain_capacity_never_exceeds_the_frame_budget :: proc(t: ^testing.T) {
	budget := 256 * 1024
	buffer := 64 * 1024
	testing.expect_value(t, terminal_session_drain_read_capacity(0, budget, buffer), buffer)
	testing.expect_value(
		t,
		terminal_session_drain_read_capacity(budget - 1024, budget, buffer),
		1024,
	)
	testing.expect_value(t, terminal_session_drain_read_capacity(budget, budget, buffer), 0)
	testing.expect_value(t, terminal_session_drain_read_capacity(budget + 1, budget, buffer), 0)
}
