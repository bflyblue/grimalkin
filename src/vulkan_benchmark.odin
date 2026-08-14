package main

import "core:fmt"
import "core:sort"
import vk "vendor:vulkan"

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

benchmark_print :: proc(app: ^Vulkan_App, samples: ^Benchmark_Samples) {
	fmt.printfln(
		"\nRender benchmark: %d measured redraws after %d warmup frames (%dx%d framebuffer)",
		len(samples.total),
		BENCHMARK_WARMUP_FRAMES,
		app.extent.width,
		app.extent.height,
	)
	fmt.printfln("  Present mode: %v", choose_present_mode(query_swapchain_support(app).present_modes))
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
}

choose_present_mode :: proc(available: []vk.PresentModeKHR) -> vk.PresentModeKHR {
	when BENCHMARK_MODE {
		for mode in available {
			if mode == .IMMEDIATE do return mode
		}
		for mode in available {
			if mode == .MAILBOX do return mode
		}
	}
	return .FIFO
}
