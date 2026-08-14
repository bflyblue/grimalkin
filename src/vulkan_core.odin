package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "vendor:glfw"
import vk "vendor:vulkan"

create_instance :: proc(app: ^Grimalkin_App) {
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

	vk_must(vk.CreateInstance(&create_info, nil, &app.instance), "creating the Vulkan instance")
}

create_debug_messenger :: proc(app: ^Grimalkin_App) {
	when ENABLE_VALIDATION {
		create_info := debug_messenger_create_info()
		vk_must(
			vk.CreateDebugUtilsMessengerEXT(app.instance, &create_info, nil, &app.debug_messenger),
			"creating the Vulkan debug messenger",
		)
	}
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

pick_physical_device :: proc(app: ^Grimalkin_App) {
	device_count: u32
	vk_must(
		vk.EnumeratePhysicalDevices(app.instance, &device_count, nil),
		"counting physical devices",
	)
	if device_count == 0 {
		fmt.panicf("no Vulkan-capable device was found")
	}

	devices := make([]vk.PhysicalDevice, device_count, context.temp_allocator)
	vk_must(
		vk.EnumeratePhysicalDevices(app.instance, &device_count, raw_data(devices)),
		"enumerating physical devices",
	)

	preference := os.get_env("GRIMALKIN_GPU_TEST_DEVICE", context.temp_allocator)
	if preference != "" && preference != "cpu" && preference != "hardware" && preference != "any" {
		fmt.panicf("GRIMALKIN_GPU_TEST_DEVICE must be cpu, hardware, or any; got %q", preference)
	}
	pass_count := 1
	if app.cursor_gpu_test && preference == "" do pass_count = 2
	for pass := 0; pass < pass_count; pass += 1 {
		require_cpu := preference == "cpu" || (app.cursor_gpu_test && preference == "" && pass == 0)
		require_hardware := preference == "hardware"
		for device in devices {
			properties: vk.PhysicalDeviceProperties
			vk.GetPhysicalDeviceProperties(device, &properties)
			if require_cpu && properties.deviceType != .CPU do continue
			if require_hardware && properties.deviceType == .CPU do continue

			families := find_queue_families(app, device)
			if !families.has_graphics ||
			   !families.has_present ||
			   !supports_required_extensions(device) ||
			   !supports_descriptor_indexing(device) {
				continue
			}

			format_count, present_mode_count := swapchain_option_counts(app, device)
			if format_count == 0 || present_mode_count == 0 {
				continue
			}

			app.physical_device = device
			app.queue_families = families
			app.texture_capacity = min(
				MAX_TEXTURE_RESOURCES_CAP,
				properties.limits.maxPerStageDescriptorSampledImages,
				properties.limits.maxDescriptorSetSampledImages,
			)
			if app.texture_capacity == 0 do continue
			app.demo.resources.textures.maximum_count = int(app.texture_capacity)
			renderer_resources_apply_texture_limits(
				&app.demo.resources,
				properties.limits.maxImageDimension2D,
				properties.limits.maxImageArrayLayers,
			)
			fmt.printfln("Using Vulkan device: %s", fixed_byte_string(&properties.deviceName))
			fmt.printfln("Texture descriptor capacity: %d", app.texture_capacity)
			return
		}
	}

	fmt.panicf(
		"no Vulkan 1.2 device supports swapchains plus non-uniform sampled-image indexing, runtime descriptor arrays, partially-bound descriptors, and variable descriptor counts",
	)
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

find_queue_families :: proc(app: ^Grimalkin_App, device: vk.PhysicalDevice) -> Queue_Families {
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

		present_supported: b32
		vk_must(
			vk.GetPhysicalDeviceSurfaceSupportKHR(
				device,
				u32(index),
				app.surface,
				&present_supported,
			),
			"querying presentation support",
		)
		if present_supported {
			result.present = u32(index)
			result.has_present = true
		}

		if result.has_graphics && result.has_present {
			break
		}
	}

	return result
}

supports_required_extensions :: proc(device: vk.PhysicalDevice) -> bool {
	count: u32
	if vk.EnumerateDeviceExtensionProperties(device, nil, &count, nil) != .SUCCESS {
		return false
	}

	available := make([]vk.ExtensionProperties, count, context.temp_allocator)
	if vk.EnumerateDeviceExtensionProperties(device, nil, &count, raw_data(available)) !=
	   .SUCCESS {
		return false
	}

	if !has_extension(available, vk.KHR_SWAPCHAIN_EXTENSION_NAME) {
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

swapchain_option_counts :: proc(app: ^Grimalkin_App, device: vk.PhysicalDevice) -> (u32, u32) {
	format_count, present_mode_count: u32
	if vk.GetPhysicalDeviceSurfaceFormatsKHR(device, app.surface, &format_count, nil) != .SUCCESS {
		return 0, 0
	}
	if vk.GetPhysicalDeviceSurfacePresentModesKHR(device, app.surface, &present_mode_count, nil) !=
	   .SUCCESS {
		return 0, 0
	}
	return format_count, present_mode_count
}

create_logical_device :: proc(app: ^Grimalkin_App) {
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
	device_extensions[0] = vk.KHR_SWAPCHAIN_EXTENSION_NAME
	device_extension_count: u32 = 1
	when ODIN_OS == .Darwin {
		device_extensions[1] = vk.KHR_PORTABILITY_SUBSET_EXTENSION_NAME
		device_extension_count = 2
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

	vk_must(
		vk.CreateDevice(app.physical_device, &create_info, nil, &app.device),
		"creating the logical device",
	)
	vk.GetDeviceQueue(app.device, app.queue_families.graphics, 0, &app.graphics_queue)
	vk.GetDeviceQueue(app.device, app.queue_families.present, 0, &app.present_queue)
}
