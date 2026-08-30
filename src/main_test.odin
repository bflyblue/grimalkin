package main

import "core:testing"

@(test)
command_line_help_does_not_start_the_application :: proc(t: ^testing.T) {
	action, _, invalid := parse_command_line({"--help"})
	testing.expect_value(t, action, Command_Line_Action.Help)
	testing.expect_value(t, invalid, "")

	action, _, invalid = parse_command_line({"-h"})
	testing.expect_value(t, action, Command_Line_Action.Help)
	testing.expect_value(t, invalid, "")
}

@(test)
command_line_version_does_not_start_the_application :: proc(t: ^testing.T) {
	action, _, invalid := parse_command_line({"--version"})
	testing.expect_value(t, action, Command_Line_Action.Version)
	testing.expect_value(t, invalid, "")

	action, _, invalid = parse_command_line({"-V"})
	testing.expect_value(t, action, Command_Line_Action.Version)
	testing.expect_value(t, invalid, "")
}

@(test)
command_line_run_modes_are_selected_without_graphics :: proc(t: ^testing.T) {
	action, mode, invalid := parse_command_line({"--demo"})
	testing.expect_value(t, action, Command_Line_Action.Run)
	testing.expect_value(t, mode, Grimalkin_Run_Mode.Demo)
	testing.expect_value(t, invalid, "")

	action, mode, invalid = parse_command_line({"--cursor-gpu-test"})
	testing.expect_value(t, action, Command_Line_Action.Run)
	testing.expect_value(t, mode, Grimalkin_Run_Mode.Cursor_Gpu_Test)
	testing.expect_value(t, invalid, "")
}

@(test)
command_line_rejects_unknown_options :: proc(t: ^testing.T) {
	action, _, invalid := parse_command_line({"--wat"})
	testing.expect_value(t, action, Command_Line_Action.Invalid)
	testing.expect_value(t, invalid, "--wat")
}
