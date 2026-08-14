package main

import c "core:c"
import "core:fmt"
import "core:mem"
import "core:strings"
import vk "vendor:vulkan"

capture_format_supported :: proc(format: vk.Format) -> bool {
	#partial switch format {
	case .B8G8R8A8_SRGB, .B8G8R8A8_UNORM, .R8G8B8A8_SRGB, .R8G8B8A8_UNORM:
		return true
	case:
		return false
	}
}

framebuffer_pixels_to_rgba :: proc(
	source: []u8,
	format: vk.Format,
	allocator := context.allocator,
) -> []u8 {
	if len(source) % 4 != 0 {
		fmt.panicf("framebuffer readback has %d bytes; expected four-byte pixels", len(source))
	}
	if !capture_format_supported(format) {
		fmt.panicf("framebuffer capture does not support Vulkan format %v", format)
	}
	pixels := make([]u8, len(source), allocator)
	if format == .R8G8B8A8_SRGB || format == .R8G8B8A8_UNORM {
		copy(pixels, source)
		return pixels
	}
	for offset := 0; offset < len(source); offset += 4 {
		pixels[offset + 0] = source[offset + 2]
		pixels[offset + 1] = source[offset + 1]
		pixels[offset + 2] = source[offset + 0]
		pixels[offset + 3] = source[offset + 3]
	}
	return pixels
}

create_capture_buffer :: proc(renderer: ^Vulkan_Renderer) {
	if !capture_format_supported(renderer.surface_format.format) {
		fmt.panicf(
			"framebuffer capture does not support swapchain format %v",
			renderer.surface_format.format,
		)
	}
	byte_count, valid_byte_count := texture_byte_count(renderer.extent.width, renderer.extent.height, 1, 4)
	if !valid_byte_count do fmt.panicf("framebuffer capture dimensions are invalid")
	renderer.capture_buffer = create_buffer(
		renderer,
		vk.DeviceSize(byte_count),
		{.TRANSFER_DST},
		{.HOST_VISIBLE, .HOST_COHERENT},
		true,
	)
}

write_frame_capture :: proc(app: ^Grimalkin_App) {
	pixels := read_framebuffer_pixels(app, context.temp_allocator)
	c_path, path_error := strings.clone_to_cstring(app.capture_path, context.temp_allocator)
	if path_error != nil {
		fmt.panicf("cannot allocate framebuffer capture path: %v", path_error)
	}
	if grimalkin_write_png_rgba(
		   c_path,
		   app.extent.width,
		   app.extent.height,
		   raw_data(pixels),
		   c.size_t(app.extent.width * 4),
	   ) !=
	   0 {
		fmt.panicf("could not write Vulkan framebuffer capture to %s", app.capture_path)
	}
	fmt.printfln(
		"Captured Vulkan framebuffer: %s (%dx%d %v)",
		app.capture_path,
		app.extent.width,
		app.extent.height,
		app.surface_format.format,
	)
}

read_framebuffer_pixels :: proc(
	app: ^Grimalkin_App,
	allocator := context.allocator,
) -> []u8 {
	source := mem.byte_slice(app.capture_buffer.mapped, int(app.capture_buffer.size))
	return framebuffer_pixels_to_rgba(source, app.surface_format.format, allocator)
}

record_frame_capture :: proc(app: ^Grimalkin_App, command_buffer: vk.CommandBuffer, image_index: u32) {
	to_transfer := vk.ImageMemoryBarrier {
		sType = .IMAGE_MEMORY_BARRIER,
		srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
		dstAccessMask = {.TRANSFER_READ},
		oldLayout = .PRESENT_SRC_KHR,
		newLayout = .TRANSFER_SRC_OPTIMAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = app.swapchain_images[image_index],
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	vk.CmdPipelineBarrier(
		command_buffer,
		{.COLOR_ATTACHMENT_OUTPUT},
		{.TRANSFER},
		{},
		0,
		nil,
		0,
		nil,
		1,
		&to_transfer,
	)

	copy_region := vk.BufferImageCopy {
		imageSubresource = {aspectMask = {.COLOR}, layerCount = 1},
		imageExtent = {width = app.extent.width, height = app.extent.height, depth = 1},
	}
	vk.CmdCopyImageToBuffer(
		command_buffer,
		app.swapchain_images[image_index],
		.TRANSFER_SRC_OPTIMAL,
		app.capture_buffer.handle,
		1,
		&copy_region,
	)

	to_host := vk.BufferMemoryBarrier {
		sType               = .BUFFER_MEMORY_BARRIER,
		srcAccessMask       = {.TRANSFER_WRITE},
		dstAccessMask       = {.HOST_READ},
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		buffer              = app.capture_buffer.handle,
		size                = app.capture_buffer.size,
	}
	vk.CmdPipelineBarrier(
		command_buffer,
		{.TRANSFER},
		{.HOST},
		{},
		0,
		nil,
		1,
		&to_host,
		0,
		nil,
	)

	to_present := vk.ImageMemoryBarrier {
		sType = .IMAGE_MEMORY_BARRIER,
		srcAccessMask = {.TRANSFER_READ},
		oldLayout = .TRANSFER_SRC_OPTIMAL,
		newLayout = .PRESENT_SRC_KHR,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = app.swapchain_images[image_index],
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	vk.CmdPipelineBarrier(
		command_buffer,
		{.TRANSFER},
		{.BOTTOM_OF_PIPE},
		{},
		0,
		nil,
		0,
		nil,
		1,
		&to_present,
	)
}
