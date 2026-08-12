package main

import "core:os"
import "core:path/filepath"
import "core:strings"

configure_macos_bundle_environment :: proc() {
	if os.get_env("VK_ICD_FILENAMES", context.temp_allocator) != "" do return
	executable_directory, executable_error := os.get_executable_directory(context.temp_allocator)
	if executable_error != nil || !strings.has_suffix(executable_directory, "/Contents/MacOS") do return
	manifest_path, manifest_error := filepath.join(
		[]string{executable_directory, "..", "Resources", "vulkan", "icd.d", "MoltenVK_icd.json"},
		context.temp_allocator,
	)
	if manifest_error == nil do _ = os.set_env("VK_ICD_FILENAMES", manifest_path)
}
