package main

import "core:fmt"
import "core:os"
import vk "vendor:vulkan"

// The GPU test suite renders into an image it owns rather than into a
// swapchain. Presentation is the only part of a frame that depends on a
// compositor, and the suite's window is never mapped, so on Wayland it would
// wait forever for swapchain images that are never released. Rendering
// offscreen removes that dependency rather than working around it, and lets the
// suite run with no display server at all.
//
// Everything downstream still indexes the usual arrays: the target publishes
// itself as a single entry in swapchain_images and image_views, so framebuffer
// creation, capture, and per-image synchronization need no headless branch.

HEADLESS_DEFAULT_WIDTH :: u32(960)
HEADLESS_DEFAULT_HEIGHT :: u32(720)

// Preference order mirrors choose_surface_format so the tests exercise the same
// transfer function the application would have been given. The override exists
// because a headless target has no surface to inherit that choice from, and
// the manual sRGB path would otherwise never be covered on a machine whose
// drivers offer an sRGB format.
headless_formats_default := [4]vk.Format {
	.B8G8R8A8_SRGB,
	.R8G8B8A8_SRGB,
	.B8G8R8A8_UNORM,
	.R8G8B8A8_UNORM,
}
headless_formats_srgb := [2]vk.Format{.B8G8R8A8_SRGB, .R8G8B8A8_SRGB}
headless_formats_unorm := [2]vk.Format{.B8G8R8A8_UNORM, .R8G8B8A8_UNORM}

headless_format_candidates :: proc(preference: string) -> []vk.Format {
	switch preference {
	case "":
		return headless_formats_default[:]
	case "srgb":
		return headless_formats_srgb[:]
	case "unorm":
		return headless_formats_unorm[:]
	}
	fmt.panicf("GRIMALKIN_GPU_TEST_FORMAT must be srgb or unorm; got %q", preference)
}

headless_choose_format :: proc(renderer: ^Vulkan_Renderer) -> vk.Format {
	preference := os.get_env("GRIMALKIN_GPU_TEST_FORMAT", context.temp_allocator)
	candidates := headless_format_candidates(preference)
	required := vk.FormatFeatureFlags{.COLOR_ATTACHMENT, .TRANSFER_SRC}
	for format in candidates {
		properties: vk.FormatProperties
		vk.GetPhysicalDeviceFormatProperties(renderer.physical_device, format, &properties)
		if (properties.optimalTilingFeatures & required) == required do return format
	}
	fmt.panicf(
		"no headless render target format among %v supports colour attachment and transfer",
		candidates,
	)
}

headless_extent :: proc() -> vk.Extent2D {
	// A fixed extent makes the suite more deterministic than a swapchain, whose
	// size follows whatever window the display server hands back.
	return {width = HEADLESS_DEFAULT_WIDTH, height = HEADLESS_DEFAULT_HEIGHT}
}

create_headless_target :: proc(renderer: ^Vulkan_Renderer) {
	format := headless_choose_format(renderer)
	renderer.surface_format = {format = format, colorSpace = .SRGB_NONLINEAR}
	renderer.manual_srgb_output = !surface_format_is_srgb(format)
	renderer.extent = headless_extent()

	image_info := vk.ImageCreateInfo {
		sType = .IMAGE_CREATE_INFO,
		imageType = .D2,
		format = format,
		extent = {width = renderer.extent.width, height = renderer.extent.height, depth = 1},
		mipLevels = 1,
		arrayLayers = 1,
		samples = {._1},
		tiling = .OPTIMAL,
		usage = {.COLOR_ATTACHMENT, .TRANSFER_SRC},
		sharingMode = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	vk_must(
		vk.CreateImage(renderer.device, &image_info, nil, &renderer.headless_image),
		"creating the headless render target",
	)

	requirements: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(renderer.device, renderer.headless_image, &requirements)
	allocate_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = requirements.size,
		memoryTypeIndex = find_memory_type(renderer, requirements.memoryTypeBits, {.DEVICE_LOCAL}),
	}
	vk_must(
		vk.AllocateMemory(renderer.device, &allocate_info, nil, &renderer.headless_memory),
		"allocating headless render target memory",
	)
	vk_must(
		vk.BindImageMemory(
			renderer.device,
			renderer.headless_image,
			renderer.headless_memory,
			0,
		),
		"binding headless render target memory",
	)

	renderer.swapchain_images = make([]vk.Image, 1)
	renderer.swapchain_images[0] = renderer.headless_image
	renderer.image_views = make([]vk.ImageView, 1)
	view_info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = renderer.headless_image,
		viewType = .D2,
		format = format,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	vk_must(
		vk.CreateImageView(renderer.device, &view_info, nil, &renderer.image_views[0]),
		"creating the headless render target view",
	)
}

destroy_headless_target :: proc(renderer: ^Vulkan_Renderer) {
	if renderer.headless_image != 0 {
		vk.DestroyImage(renderer.device, renderer.headless_image, nil)
		renderer.headless_image = 0
	}
	if renderer.headless_memory != 0 {
		vk.FreeMemory(renderer.device, renderer.headless_memory, nil)
		renderer.headless_memory = 0
	}
}
