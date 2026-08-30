package main

import "core:testing"
import vk "vendor:vulkan"

gpu_test_candidate :: proc(device_type: vk.PhysicalDeviceType, index: int) -> Gpu_Device_Candidate {
	result := Gpu_Device_Candidate{enumeration_index = index}
	result.properties.deviceType = device_type
	return result
}

expect_gpu_order :: proc(t: ^testing.T, actual: []int, expected: []int) {
	testing.expect_value(t, len(actual), len(expected))
	for value, index in actual {
		if index >= len(expected) do break
		testing.expect_value(t, value, expected[index])
	}
}

@(test)
gpu_candidate_order_preserves_enumeration_for_automatic :: proc(t: ^testing.T) {
	candidates := []Gpu_Device_Candidate {
		gpu_test_candidate(.DISCRETE_GPU, 0),
		gpu_test_candidate(.INTEGRATED_GPU, 1),
		gpu_test_candidate(.CPU, 2),
	}
	indices := ordered_gpu_candidate_indices(candidates, .Automatic)
	defer delete(indices)
	expect_gpu_order(t, indices[:], []int{0, 1, 2})
}

@(test)
gpu_candidate_order_prioritizes_requested_class_and_keeps_fallbacks :: proc(t: ^testing.T) {
	candidates := []Gpu_Device_Candidate {
		gpu_test_candidate(.DISCRETE_GPU, 0),
		gpu_test_candidate(.INTEGRATED_GPU, 1),
		gpu_test_candidate(.CPU, 2),
	}
	integrated := ordered_gpu_candidate_indices(candidates, .Integrated)
	defer delete(integrated)
	expect_gpu_order(t, integrated[:], []int{1, 0, 2})
	discrete := ordered_gpu_candidate_indices(candidates, .Discrete)
	defer delete(discrete)
	expect_gpu_order(t, discrete[:], []int{0, 1, 2})
}

@(test)
gpu_preference_class_matching_is_explicit :: proc(t: ^testing.T) {
	testing.expect(t, gpu_preference_matches(.Automatic, .CPU))
	testing.expect(t, gpu_preference_matches(.Integrated, .INTEGRATED_GPU))
	testing.expect(t, !gpu_preference_matches(.Integrated, .DISCRETE_GPU))
	testing.expect(t, gpu_preference_matches(.Discrete, .DISCRETE_GPU))
	testing.expect(t, !gpu_preference_matches(.Discrete, .VIRTUAL_GPU))
}
