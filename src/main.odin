package main

import "core:fmt"
import "core:os"

Grimalkin_Run_Mode :: enum u8 {
	Terminal,
	Demo,
	Cursor_Gpu_Test,
}

Command_Line_Action :: enum u8 {
	Run,
	Help,
	Version,
	Invalid,
}

COMMAND_LINE_HELP :: `Usage: grimalkin [OPTION]

Options:
  --demo              run the deterministic display demo
  --cursor-gpu-test   run the offscreen GPU test suite
  -h, --help          show this help and exit
  -V, --version       show the version and exit`

parse_command_line :: proc(arguments: []string) -> (Command_Line_Action, Grimalkin_Run_Mode, string) {
	mode := Grimalkin_Run_Mode.Demo if BENCHMARK_MODE else .Terminal
	for argument in arguments {
		switch argument {
		case "--demo":
			mode = .Demo
		case "--cursor-gpu-test":
			mode = .Cursor_Gpu_Test
		case "-h", "--help":
			return .Help, mode, ""
		case "-V", "--version":
			return .Version, mode, ""
		case:
			return .Invalid, mode, argument
		}
	}
	return .Run, mode, ""
}

main :: proc() {
	action, mode, invalid_argument := parse_command_line(os.args[1:])
	switch action {
	case .Help:
		fmt.println(COMMAND_LINE_HELP)
		return
	case .Version:
		fmt.printfln("grimalkin %s", application_version())
		return
	case .Invalid:
		fmt.eprintfln("grimalkin: unknown option: %s", invalid_argument)
		fmt.eprintln("Try 'grimalkin --help' for more information.")
		os.exit(2)
	case .Run:
	}
	configure_macos_bundle_environment()
	run_grimalkin(mode)
}
