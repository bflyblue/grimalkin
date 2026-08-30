package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "vendor:glfw"
import vk "vendor:vulkan"

create_instance :: proc(app: ^Grimalkin_App) -> bool {
	application_info := vk.ApplicationInfo {
		sType              = .APPLICATION_INFO,
		pApplicationName   = "Grimalkin",
		applicationVersion = vk.MAKE_VERSION(0, 1, 0),
		pEngineName        = "Grimalkin Renderer",
		engineVersion      = vk.MAKE_VERSION(0, 1, 0),
		apiVersion         = vk.API_VERSION_1_2,
	}

	extensions := slice.clone_to_dynamic(
		glfw.GetRequiredInstanceExtensions(),
		context.temp_allocator,
	)
	when ODIN_OS == .Darwin {
		append(&extensions, vk.KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)
	}
	when ENABLE_VALIDATION {
		append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
	}

	create_info := vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		pApplicationInfo        = &application_info,
		enabledExtensionCount   = u32(len(extensions)),
		ppEnabledExtensionNames = raw_data(extensions),
	}

	when ODIN_OS == .Darwin {
		create_info.flags |= {.ENUMERATE_PORTABILITY_KHR}
	}

	when ENABLE_VALIDATION {
		validation_layers := []cstring{"VK_LAYER_KHRONOS_validation"}
		create_info.enabledLayerCount = u32(len(validation_layers))
		create_info.ppEnabledLayerNames = raw_data(validation_layers)

		debug_info := debug_messenger_create_info()
		create_info.pNext = &debug_info
	}

	result := vk.CreateInstance(&create_info, nil, &app.instance)
	if result != .SUCCESS {
		fmt.eprintfln("grimalkin: Vulkan instance creation failed: %v", result)
		return false
	}
	return true
}

create_debug_messenger :: proc(app: ^Grimalkin_App) -> bool {
	when ENABLE_VALIDATION {
		create_info := debug_messenger_create_info()
		result := vk.CreateDebugUtilsMessengerEXT(app.instance, &create_info, nil, &app.debug_messenger)
		if result != .SUCCESS {
			fmt.eprintfln("grimalkin: Vulkan debug messenger creation failed: %v", result)
			return false
		}
	}
	return true
}

debug_messenger_create_info :: proc() -> vk.DebugUtilsMessengerCreateInfoEXT {
	return vk.DebugUtilsMessengerCreateInfoEXT {
		sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
		messageSeverity = {.WARNING, .ERROR},
		messageType = {.GENERAL, .VALIDATION, .PERFORMANCE},
		pfnUserCallback = vulkan_debug_callback,
	}
}

vulkan_debug_callback :: proc "system" (
	severity: vk.DebugUtilsMessageSeverityFlagsEXT,
	message_types: vk.DebugUtilsMessageTypeFlagsEXT,
	callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT,
	user_data: rawptr,
) -> b32 {
	context = runtime.default_context()
	fmt.eprintfln("Vulkan [%v, %v]: %s", severity, message_types, callback_data.pMessage)
	return false
}

gpu_preference_matches :: proc(preference: Gpu_Preference, device_type: vk.PhysicalDeviceType) -> bool {
	switch preference {
	case .Automatic:  return true
	case .Integrated: return device_type == .INTEGRATED_GPU
	case .Discrete:   return device_type == .DISCRETE_GPU
	}
	return true
}

gpu_candidate_texture_capacity :: proc(properties: vk.PhysicalDeviceProperties) -> u32 {
	return min(
		MAX_TEXTURE_RESOURCES_CAP,
		properties.limits.maxPerStageDescriptorSampledImages,
		properties.limits.maxDescriptorSetSampledImages,
	)
}

gpu_text_atlas_budget :: proc(device: vk.PhysicalDevice) -> u64 {
	memory: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(device, &memory)
	largest_device_local: u64
	for index := u32(0); index < memory.memoryHeapCount; index += 1 {
		heap := memory.memoryHeaps[index]
		if .DEVICE_LOCAL in heap.flags do largest_device_local = max(largest_device_local, u64(heap.size))
	}
	return clamp(largest_device_local / 64, u64(64 * 1024 * 1024), u64(256 * 1024 * 1024))
}

gpu_candidate_supports_resources :: proc(app: ^Grimalkin_App, properties: vk.PhysicalDeviceProperties) -> bool {
	capacity := gpu_candidate_texture_capacity(properties)
	if capacity == 0 do return false
	if app.demo == nil do return true
	live_resources := 0
	for resource in app.demo.resources.textures.resources {
		if resource == nil do continue
		live_resources += 1
		if resource.width > properties.limits.maxImageDimension2D ||
		   resource.height > properties.limits.maxImageDimension2D ||
		   resource.layers > properties.limits.maxImageArrayLayers {
			return false
		}
	}
	return live_resources <= int(capacity)
}

gpu_candidate_surface_suitable :: proc(app: ^Grimalkin_App, device: vk.PhysicalDevice) -> bool {
	if app.headless do return true
	capabilities: vk.SurfaceCapabilitiesKHR
	if vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(device, app.surface, &capabilities) != .SUCCESS {
		return false
	}
	if .COLOR_ATTACHMENT not_in capabilities.supportedUsageFlags do return false
	if app.framebuffer_readback && .TRANSFER_SRC not_in capabilities.supportedUsageFlags do return false
	_, composite_alpha_ok := try_choose_composite_alpha(capabilities.supportedCompositeAlpha)
	if !composite_alpha_ok do return false

	format_count: u32
	if vk.GetPhysicalDeviceSurfaceFormatsKHR(device, app.surface, &format_count, nil) != .SUCCESS || format_count == 0 {
		return false
	}
	formats := make([]vk.SurfaceFormatKHR, format_count, context.temp_allocator)
	if vk.GetPhysicalDeviceSurfaceFormatsKHR(device, app.surface, &format_count, raw_data(formats)) != .SUCCESS {
		return false
	}
	_, format_ok := try_choose_surface_format(formats)
	if !format_ok do return false

	present_mode_count: u32
	return vk.GetPhysicalDeviceSurfacePresentModesKHR(device, app.surface, &present_mode_count, nil) == .SUCCESS &&
		present_mode_count > 0
}

discover_gpu_candidates :: proc(app: ^Grimalkin_App) -> [dynamic]Gpu_Device_Candidate {
	device_count: u32
	if vk.EnumeratePhysicalDevices(app.instance, &device_count, nil) != .SUCCESS || device_count == 0 {
		return nil
	}
	devices := make([]vk.PhysicalDevice, device_count, context.temp_allocator)
	if vk.EnumeratePhysicalDevices(app.instance, &device_count, raw_data(devices)) != .SUCCESS {
		return nil
	}
	candidates: [dynamic]Gpu_Device_Candidate
	for device, index in devices {
		properties: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(device, &properties)
		families, families_ok := find_queue_families(app, device)
		if !families_ok || !families.has_graphics || !families.has_present ||
		   !supports_required_extensions(device, app.headless) ||
		   !supports_descriptor_indexing(device) ||
		   !gpu_candidate_supports_resources(app, properties) ||
		   !gpu_candidate_surface_suitable(app, device) {
			continue
		}
		append(&candidates, Gpu_Device_Candidate {
			device = device,
			properties = properties,
			queue_families = families,
			enumeration_index = index,
		})
	}
	return candidates
}

ordered_gpu_candidate_indices :: proc(
	candidates: []Gpu_Device_Candidate,
	preference: Gpu_Preference,
	allocator := context.temp_allocator,
) -> [dynamic]int {
	indices := make([dynamic]int, 0, len(candidates), allocator)
	if preference != .Automatic {
		for candidate, index in candidates {
			if gpu_preference_matches(preference, candidate.properties.deviceType) do append(&indices, index)
		}
	}
	for candidate, index in candidates {
		if preference == .Automatic || !gpu_preference_matches(preference, candidate.properties.deviceType) {
			append(&indices, index)
		}
	}
	return indices
}

gpu_selection_status_update_candidates :: proc(app: ^Grimalkin_App, candidates: []Gpu_Device_Candidate) {
	app.gpu_selection.suitable_count = len(candidates)
	app.gpu_selection.integrated_available = false
	app.gpu_selection.discrete_available = false
	for candidate in candidates {
		if candidate.properties.deviceType == .INTEGRATED_GPU {
			app.gpu_selection.integrated_available = true
		} else if candidate.properties.deviceType == .DISCRETE_GPU {
			app.gpu_selection.discrete_available = true
		}
	}
}

pick_physical_device :: proc(app: ^Grimalkin_App, excluded: []vk.PhysicalDevice = nil) -> bool {
	candidates := discover_gpu_candidates(app)
	defer delete(candidates)
	gpu_selection_status_update_candidates(app, candidates[:])
	if len(candidates) == 0 {
		fmt.eprintln("grimalkin: no Vulkan 1.2 device is compatible with the current window surface and renderer requirements")
		return false
	}

	test_preference := os.get_env("GRIMALKIN_GPU_TEST_DEVICE", context.temp_allocator)
	if test_preference != "" && test_preference != "cpu" && test_preference != "hardware" && test_preference != "any" {
		fmt.eprintfln("grimalkin: GRIMALKIN_GPU_TEST_DEVICE must be cpu, hardware, or any; got %q", test_preference)
		return false
	}
	indices := ordered_gpu_candidate_indices(candidates[:], app.settings.gpu_preference)
	defer delete(indices)
	has_cpu_candidate := false
	for candidate in candidates do has_cpu_candidate = has_cpu_candidate || candidate.properties.deviceType == .CPU
	for index in indices {
		candidate := candidates[index]
		excluded_candidate := false
		for device in excluded {
			if device == candidate.device do excluded_candidate = true
		}
		if excluded_candidate do continue
		if app.cursor_gpu_test {
			require_cpu := test_preference == "cpu" || (test_preference == "" && has_cpu_candidate)
			require_hardware := test_preference == "hardware"
			if require_cpu && candidate.properties.deviceType != .CPU do continue
			if require_hardware && candidate.properties.deviceType == .CPU do continue
		}
		app.physical_device = candidate.device
		app.queue_families = candidate.queue_families
		app.texture_capacity = gpu_candidate_texture_capacity(candidate.properties)
		if !create_logical_device(app) {
			fmt.eprintfln(
				"grimalkin: could not create a logical device on %s; trying the next adapter",
				fixed_byte_string(&candidate.properties.deviceName),
			)
			continue
		}
		app.demo.resources.textures.maximum_count = int(app.texture_capacity)
		renderer_resources_apply_texture_limits(
			&app.demo.resources,
			candidate.properties.limits.maxImageDimension2D,
			candidate.properties.limits.maxImageArrayLayers,
			gpu_text_atlas_budget(candidate.device),
		)
		delete(app.gpu_selection.active_name)
		app.gpu_selection.active_name = strings.clone(fixed_byte_string(&candidate.properties.deviceName))
		app.gpu_selection.active_type = candidate.properties.deviceType
		app.gpu_selection.fallback_active = app.settings.gpu_preference != .Automatic &&
			!gpu_preference_matches(app.settings.gpu_preference, candidate.properties.deviceType)
		fmt.printfln("Using Vulkan device: %s", app.gpu_selection.active_name)
		fmt.printfln("Texture descriptor capacity: %d", app.texture_capacity)
		return true
	}
	fmt.eprintln("grimalkin: no Vulkan device matches the requested GPU test preference")
	return false
}

supports_descriptor_indexing :: proc(device: vk.PhysicalDevice) -> bool {
	indexing := vk.PhysicalDeviceDescriptorIndexingFeatures {
		sType = .PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_FEATURES,
	}
	features := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &indexing,
	}
	vk.GetPhysicalDeviceFeatures2(device, &features)
	return(
		bool(indexing.shaderSampledImageArrayNonUniformIndexing) &&
		bool(indexing.descriptorBindingPartiallyBound) &&
		bool(indexing.descriptorBindingVariableDescriptorCount) &&
		bool(indexing.runtimeDescriptorArray) \
	)
}

find_queue_families :: proc(app: ^Grimalkin_App, device: vk.PhysicalDevice) -> (Queue_Families, bool) {
	result := Queue_Families{}
	count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, nil)

	properties := make([]vk.QueueFamilyProperties, count, context.temp_allocator)
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, raw_data(properties))

	for property, index in properties {
		if .GRAPHICS in property.queueFlags {
			result.graphics = u32(index)
			result.has_graphics = true
		}

		// A headless renderer has no surface to query. Nothing presents, so the
		// graphics queue stands in and the search ends as soon as one is found.
		if app.surface == 0 {
			result.present = result.graphics
			result.has_present = result.has_graphics
		} else {
			present_supported: b32
			if vk.GetPhysicalDeviceSurfaceSupportKHR(
					device,
					u32(index),
					app.surface,
					&present_supported,
				) != .SUCCESS {
					return {}, false
				}
			if present_supported {
				result.present = u32(index)
				result.has_present = true
			}
		}

		if result.has_graphics && result.has_present {
			break
		}
	}

	return result, true
}

supports_required_extensions :: proc(device: vk.PhysicalDevice, headless := false) -> bool {
	count: u32
	if vk.EnumerateDeviceExtensionProperties(device, nil, &count, nil) != .SUCCESS {
		return false
	}

	available := make([]vk.ExtensionProperties, count, context.temp_allocator)
	if vk.EnumerateDeviceExtensionProperties(device, nil, &count, raw_data(available)) !=
	   .SUCCESS {
		return false
	}

	// Nothing is presented headless, so the swapchain extension is not needed.
	if !headless && !has_extension(available, vk.KHR_SWAPCHAIN_EXTENSION_NAME) {
		return false
	}
	when ODIN_OS == .Darwin {
		if !has_extension(available, vk.KHR_PORTABILITY_SUBSET_EXTENSION_NAME) {
			return false
		}
	}
	return true
}

has_extension :: proc(available: []vk.ExtensionProperties, wanted: cstring) -> bool {
	for &extension in available {
		if fixed_byte_string(&extension.extensionName) == string(wanted) {
			return true
		}
	}
	return false
}

create_logical_device :: proc(app: ^Grimalkin_App) -> bool {
	priority := f32(1.0)
	queue_infos: [2]vk.DeviceQueueCreateInfo
	queue_infos[0] = vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = app.queue_families.graphics,
		queueCount       = 1,
		pQueuePriorities = &priority,
	}
	queue_info_count: u32 = 1

	if app.queue_families.present != app.queue_families.graphics {
		queue_infos[1] = vk.DeviceQueueCreateInfo {
			sType            = .DEVICE_QUEUE_CREATE_INFO,
			queueFamilyIndex = app.queue_families.present,
			queueCount       = 1,
			pQueuePriorities = &priority,
		}
		queue_info_count = 2
	}

	device_extensions: [2]cstring
	device_extension_count: u32 = 0
	if !app.headless {
		device_extensions[device_extension_count] = vk.KHR_SWAPCHAIN_EXTENSION_NAME
		device_extension_count += 1
	}
	when ODIN_OS == .Darwin {
		device_extensions[device_extension_count] = vk.KHR_PORTABILITY_SUBSET_EXTENSION_NAME
		device_extension_count += 1
	}

	indexing := vk.PhysicalDeviceDescriptorIndexingFeatures {
		sType                                     = .PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_FEATURES,
		shaderSampledImageArrayNonUniformIndexing = true,
		descriptorBindingPartiallyBound           = true,
		descriptorBindingVariableDescriptorCount  = true,
		runtimeDescriptorArray                    = true,
	}
	create_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &indexing,
		queueCreateInfoCount    = queue_info_count,
		pQueueCreateInfos       = &queue_infos[0],
		enabledExtensionCount   = device_extension_count,
		ppEnabledExtensionNames = &device_extensions[0],
	}

	if vk.CreateDevice(app.physical_device, &create_info, nil, &app.device) != .SUCCESS {
		app.device = nil
		return false
	}
	vk.GetDeviceQueue(app.device, app.queue_families.graphics, 0, &app.graphics_queue)
	vk.GetDeviceQueue(app.device, app.queue_families.present, 0, &app.present_queue)
	return true
}
