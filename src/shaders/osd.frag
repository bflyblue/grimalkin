#version 450
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_GOOGLE_include_directive : require

#include "colour.glsl"
#include "text_visual.glsl"

layout(set = 0, binding = 0, std430) readonly buffer CellBuffer {
	uvec4 cells[];
};

layout(set = 0, binding = 1, std430) readonly buffer VisualBuffer {
	VisualRecord visuals[];
};

layout(set = 0, binding = 3) uniform sampler2DArray resources[];

layout(push_constant) uniform OsdLayout {
	uvec4 frame;
	ivec4 panel;
	uvec4 grid;
	ivec4 font;
} layout_data;

layout(location = 0) out vec4 output_colour;

void write_output(vec4 linear_premultiplied) {
	if (layout_data.frame.z != 0u) {
		linear_premultiplied.rgb = linear_to_srgb(linear_premultiplied.rgb);
	}
	output_colour = linear_premultiplied;
}

void main() {
	ivec2 pixel = ivec2(gl_FragCoord.xy);
	ivec2 panel_min = layout_data.panel.xy;
	ivec2 panel_max = panel_min + layout_data.panel.zw;
	bool inside_panel = all(greaterThanEqual(pixel, panel_min)) &&
		all(lessThan(pixel, panel_max));
	if (!inside_panel) {
		write_output(vec4(0.0, 0.0, 0.0, 0.45));
		return;
	}

	vec4 colour = vec4(srgb_to_linear(vec3(16.0, 21.0, 33.0) / 255.0), 1.0);
	ivec2 edge = min(pixel - panel_min, panel_max - pixel - ivec2(1));
	if (min(edge.x, edge.y) < 2) {
		colour = vec4(srgb_to_linear(vec3(22.0, 140.0, 255.0) / 255.0), 1.0);
		write_output(colour);
		return;
	}

	ivec2 local = pixel - layout_data.font.yz;
	ivec2 cell_size = ivec2(layout_data.grid.zw);
	ivec2 grid_size = ivec2(layout_data.grid.xy);
	ivec2 cell_position = local / cell_size;
	if (any(lessThan(local, ivec2(0))) || any(greaterThanEqual(cell_position, grid_size))) {
		write_output(colour);
		return;
	}

	uint cell_index = uint(cell_position.y * grid_size.x + cell_position.x);
	uvec4 cell = cells[cell_index];
	vec4 foreground = unpack_srgb_rgba8(cell.y);
	vec4 background = unpack_srgb_rgba8(cell.z);
	colour.rgb = background.rgb * background.a + colour.rgb * (1.0 - background.a);
	ivec2 within_cell = local - cell_position * cell_size;
	VisualRecord visual = visuals[cell.x];
	uint visual_kind = visual.texture.z;
	ivec2 within_visual = within_cell - visual.destination_rect.xy;
	if (visual_kind != 0u && all(greaterThanEqual(within_visual, ivec2(0))) &&
	    all(lessThan(within_visual, visual.destination_rect.zw))) {
		ivec2 source_pixel = ivec2(visual.source_rect.xy) +
			within_visual * ivec2(visual.source_rect.zw) / visual.destination_rect.zw;
		uint texture_index = visual.texture.x;
		if (visual_kind == VISUAL_MASK) {
			float coverage = texelFetch(
				resources[nonuniformEXT(texture_index)],
				ivec3(source_pixel, int(visual.texture.y)), 0
			).r;
			coverage = adjust_coverage(coverage, layout_data.frame.w) * foreground.a;
			colour.rgb = foreground.rgb * coverage + colour.rgb * (1.0 - coverage);
		} else if (visual_kind == VISUAL_SUBPIXEL_MASK) {
			vec4 coverage = texelFetch(
				resources[nonuniformEXT(texture_index)],
				ivec3(source_pixel, int(visual.texture.y)), 0
			);
			vec3 component_alpha = adjust_coverage(coverage.rgb, layout_data.frame.w) * foreground.a;
			colour.rgb = foreground.rgb * component_alpha +
				colour.rgb * (vec3(1.0) - component_alpha);
		}
	}
	write_output(colour);
}
