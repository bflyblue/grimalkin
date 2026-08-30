package main

import "core:fmt"
import "core:sort"
import "core:time"
import vk "vendor:vulkan"

BENCHMARK_INDEX_ENTRIES :: 1024
BENCHMARK_INDEX_LOOKUPS :: 100_000

benchmark_print_index_result :: proc(label: string, linear_start, indexed_start: time.Tick, checksum: u64) {
	linear_ms := time.duration_milliseconds(time.tick_diff(linear_start, indexed_start))
	indexed_ms := time.duration_milliseconds(time.tick_since(indexed_start))
	fmt.printfln(
		"  %s lookup: linear %.3f ms, indexed %.3f ms (%d entries, %d lookups, checksum %d)",
		label,
		linear_ms,
		indexed_ms,
		BENCHMARK_INDEX_ENTRIES,
		BENCHMARK_INDEX_LOOKUPS,
		checksum,
	)
}

benchmark_graphics_indexes :: proc() {
	snapshot := Terminal_Snapshot{}
	defer terminal_snapshot_destroy(&snapshot)
	snapshot.images = make([]Terminal_Image, BENCHMARK_INDEX_ENTRIES)
	snapshot.image_indices = make(map[u32]int)
	snapshot.placements = make([]Terminal_Placement, BENCHMARK_INDEX_ENTRIES)
	for index in 0 ..< BENCHMARK_INDEX_ENTRIES {
		image_id := u32(index + 1)
		snapshot.images[index].image_id = image_id
		snapshot.image_indices[image_id] = index
		snapshot.placements[index] = {
			image_id = image_id,
			placement_id = image_id,
			is_virtual = true,
		}
	}
	terminal_snapshot_index_virtual_placements(&snapshot)

	checksum := u64(0)
	linear_start := time.tick_now()
	for iteration in 0 ..< BENCHMARK_INDEX_LOOKUPS {
		image_id := u32(iteration % BENCHMARK_INDEX_ENTRIES + 1)
		for &image in snapshot.images {
			if image.image_id == image_id {
				checksum += u64(image.image_id)
				break
			}
		}
	}
	indexed_start := time.tick_now()
	for iteration in 0 ..< BENCHMARK_INDEX_LOOKUPS {
		image_id := u32(iteration % BENCHMARK_INDEX_ENTRIES + 1)
		if image, found := terminal_snapshot_image(&snapshot, image_id); found {
			checksum += u64(image.image_id)
		}
	}
	benchmark_print_index_result("Kitty image", linear_start, indexed_start, checksum)

	checksum = 0
	linear_start = time.tick_now()
	for iteration in 0 ..< BENCHMARK_INDEX_LOOKUPS {
		placement_id := u32(iteration % BENCHMARK_INDEX_ENTRIES + 1)
		for &placement in snapshot.placements {
			if placement.is_virtual &&
			   placement.image_id == placement_id &&
			   placement.placement_id == placement_id {
				checksum += u64(placement.placement_id)
				break
			}
		}
	}
	indexed_start = time.tick_now()
	for iteration in 0 ..< BENCHMARK_INDEX_LOOKUPS {
		placement_id := u32(iteration % BENCHMARK_INDEX_ENTRIES + 1)
		if placement, found := terminal_snapshot_virtual_placement(
			&snapshot,
			placement_id,
			placement_id,
		); found {
			checksum += u64(placement.placement_id)
		}
	}
	benchmark_print_index_result("virtual placement", linear_start, indexed_start, checksum)
}

benchmark_fallback_face_index :: proc() {
	resources := Renderer_Resources {
		font_face_lookup = make(map[Font_Instance_Key]^Font_Face),
	}
	faces := make([]Font_Face, BENCHMARK_INDEX_ENTRIES)
	paths := make([]string, BENCHMARK_INDEX_ENTRIES)
	defer {
		delete(resources.font_face_lookup)
		for path in paths do delete(path)
		delete(paths)
		delete(faces)
	}
	config := font_render_config_grayscale()
	for index in 0 ..< BENCHMARK_INDEX_ENTRIES {
		paths[index] = fmt.aprintf("/benchmark/fallback-%d.ttf", index)
		faces[index].id = u32(index)
		faces[index].font.key = font_instance_key(paths[index], i32(index), 16, .Regular, config)
		resources.font_face_lookup[faces[index].font.key] = &faces[index]
	}

	checksum := u64(0)
	linear_start := time.tick_now()
	for iteration in 0 ..< BENCHMARK_INDEX_LOOKUPS {
		index := iteration % BENCHMARK_INDEX_ENTRIES
		key := font_instance_key(paths[index], i32(index), 16, .Regular, config)
		for &face in faces {
			if face.font.key == key {
				checksum += u64(face.id)
				break
			}
		}
	}
	indexed_start := time.tick_now()
	for iteration in 0 ..< BENCHMARK_INDEX_LOOKUPS {
		index := iteration % BENCHMARK_INDEX_ENTRIES
		key := font_instance_key(paths[index], i32(index), 16, .Regular, config)
		if face := resources.font_face_lookup[key]; face != nil {
			checksum += u64(face.id)
		}
	}
	benchmark_print_index_result("fallback face", linear_start, indexed_start, checksum)
}

benchmark_samples_destroy :: proc(samples: ^Benchmark_Samples) {
	delete(samples.cpu_redraw)
	delete(samples.gpu_draw)
	delete(samples.total)
}

benchmark_add_sample :: proc(samples: ^Benchmark_Samples, sample: Benchmark_Frame_Sample) {
	append(&samples.cpu_redraw, sample.cpu_redraw_ms)
	append(&samples.total, sample.total_ms)
	samples.cell_bytes_uploaded += sample.cell_bytes_uploaded
	samples.visual_bytes_uploaded += sample.visual_bytes_uploaded
	if sample.has_gpu_time {
		append(&samples.gpu_draw, sample.gpu_draw_ms)
	}
}

benchmark_summarize :: proc(values: []f64) -> Benchmark_Summary {
	if len(values) == 0 {
		return {}
	}
	sorted := make([]f64, len(values), context.temp_allocator)
	copy(sorted, values)
	sort.sort(sort.slice_interface(&sorted))

	sum := f64(0)
	for value in sorted {
		sum += value
	}
	return {
		minimum = sorted[0],
		median = sorted[(len(sorted) - 1) / 2],
		p95 = sorted[int(f64(len(sorted) - 1) * 0.95)],
		mean = sum / f64(len(sorted)),
		maximum = sorted[len(sorted) - 1],
	}
}

benchmark_print_series :: proc(label: string, summary: Benchmark_Summary) {
	fmt.printfln(
		"  %s: mean %.3f ms, p50 %.3f, p95 %.3f, min %.3f, max %.3f",
		label,
		summary.mean,
		summary.median,
		summary.p95,
		summary.minimum,
		summary.maximum,
	)
}

benchmark_print :: proc(app: ^Grimalkin_App, samples: ^Benchmark_Samples) {
	fmt.printfln(
		"\nRender benchmark: %d measured redraws after %d warmup frames (%dx%d framebuffer)",
		len(samples.total),
		BENCHMARK_WARMUP_FRAMES,
		app.extent.width,
		app.extent.height,
	)
	swapchain_support, _ := query_swapchain_support(app)
	fmt.printfln("  Present mode: %v", choose_present_mode(swapchain_support.present_modes))
	benchmark_print_series("CPU prepare/record/submit", benchmark_summarize(samples.cpu_redraw[:]))
	if len(samples.gpu_draw) == len(samples.total) {
		gpu := benchmark_summarize(samples.gpu_draw[:])
		benchmark_print_series("GPU timestamp draw", gpu)
		if gpu.mean > 0 {
			fmt.printfln("  GPU-only throughput estimate: %.0f redraws/s", 1000.0 / gpu.mean)
		}
	} else {
		fmt.println("  GPU timestamp draw: unavailable on this graphics queue")
	}
	benchmark_print_series("Total serialized redraw", benchmark_summarize(samples.total[:]))
	if len(samples.total) > 0 {
		fmt.printfln(
			"  Metadata uploaded per redraw: %.0f cell bytes, %.0f visual bytes",
			f64(samples.cell_bytes_uploaded) / f64(len(samples.total)),
			f64(samples.visual_bytes_uploaded) / f64(len(samples.total)),
		)
	}
	fmt.println(
		"  Total includes presentation and the demo's deliberate per-frame queue wait.",
	)
	fmt.println("Indexed hot-path microbenchmarks:")
	benchmark_graphics_indexes()
	benchmark_fallback_face_index()
}

choose_present_mode :: proc(available: []vk.PresentModeKHR) -> vk.PresentModeKHR {
	when BENCHMARK_MODE {
		// Avoid a vertical-sync ceiling in benchmark measurements when the driver
		// offers it. Normal rendering keeps universally supported FIFO.
		for mode in available {
			if mode == .IMMEDIATE do return mode
		}
		for mode in available {
			if mode == .MAILBOX do return mode
		}
	}
	return .FIFO
}
