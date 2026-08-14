package main

import "core:fmt"
import "core:strings"
import vk "vendor:vulkan"

fixed_byte_string :: proc(bytes: ^[$N]byte) -> string {
	return strings.truncate_to_byte(string(bytes[:]), 0)
}

vk_must :: proc(result: vk.Result, operation: string, location := #caller_location) {
	if result != .SUCCESS {
		fmt.panicf("Vulkan failed while %s: %v", operation, result, loc = location)
	}
}
