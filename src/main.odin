package main

import "core:os"

Grimalkin_Run_Mode :: enum u8 {
	Terminal,
	Demo,
	Cursor_Gpu_Test,
}

main :: proc() {
	configure_macos_bundle_environment()
	mode := Grimalkin_Run_Mode.Demo if BENCHMARK_MODE else .Terminal
	for argument in os.args[1:] {
		if argument == "--demo" do mode = .Demo
		if argument == "--cursor-gpu-test" do mode = .Cursor_Gpu_Test
	}
	run_grimalkin(mode)
}
