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

layout(set = 0, binding = 2, std430) readonly buffer DecorationBuffer {
	uint decoration_colours[];
};

layout(set = 0, binding = 3) uniform sampler2DArray resources[];

// Kitty placements with -1073741824 <= z < 0 draw above the cell background
// and below the text, which no separate pass can express while this one writes
// background and glyph together. They are composited here instead, between the
// two. A second set keeps binding 3 above as the last binding of set 0, which
// its variable descriptor count requires.
layout(set = 1, binding = 0, std430) readonly buffer ImagePlacementBuffer {
	VisualRecord below_text[];
};

layout(push_constant) uniform TextLayout {
	uvec4 grid; // columns, rows, cell width, cell height
	ivec4 font; // baseline, viewport x/y, manually encode output as sRGB
	uvec4 cursor; // cell x/y, style plus visibility, packed sRGB RGBA
	uvec4 effects; // blinking-text opacity, text contrast, below-text count, reserved
} layout_data;

layout(location = 0) out vec4 output_colour;

const uint CELL_UNDERLINE_MASK = 7u;
const uint CELL_STRIKETHROUGH = 1u << 3;
const uint CELL_OVERLINE = 1u << 4;
const uint CELL_BLINK = 1u << 5;
const uint CURSOR_VISIBLE = 1u << 8;
const uint CURSOR_OPACITY_SHIFT = 16u;
const uint CURSOR_OPACITY_MASK = 0xffffu;

vec4 premultiply(vec4 straight) {
	return vec4(straight.rgb * straight.a, straight.a);
}

vec4 over(vec4 source, vec4 destination) {
	return source + destination * (1.0 - source.a);
}

void write_output(vec4 linear_premultiplied) {
	vec3 linear_rgb = linear_premultiplied.rgb;
	if (layout_data.font.w != 0) linear_rgb = linear_to_srgb(linear_rgb);
	output_colour = vec4(linear_rgb, linear_premultiplied.a);
}

// Walks the below-text placements in draw order. The list is bounded and the
// count is zero for the overwhelming majority of frames, so this compiles down
// to a single comparison whenever no such image is on screen.
vec4 composite_below_text(vec4 destination, ivec2 pixel) {
	uint count = layout_data.effects.z;
	for (uint index = 0u; index < count; index += 1u) {
		VisualRecord record = below_text[index];
		ivec2 within = pixel - record.destination_rect.xy;
		if (any(lessThan(within, ivec2(0))) ||
		    any(greaterThanEqual(within, record.destination_rect.zw))) {
			continue;
		}
		uint texture_index = record.texture.x;
		ivec3 extent = textureSize(resources[nonuniformEXT(texture_index)], 0);
		vec2 position = vec2(record.source_rect.xy) +
			(vec2(within) + vec2(0.5)) * vec2(record.source_rect.zw) /
			vec2(record.destination_rect.zw);
		vec4 source_colour = textureLod(
			resources[nonuniformEXT(texture_index)],
			vec3(position / vec2(extent.xy), float(record.texture.y)),
			0.0
		);
		destination = over(source_colour, destination);
	}
	return destination;
}

void main() {
	ivec2 pixel = ivec2(gl_FragCoord.xy) - layout_data.font.yz;
	ivec2 cell_size = ivec2(layout_data.grid.zw);
	ivec2 grid_size = ivec2(layout_data.grid.xy);
	ivec2 cell_position = pixel / cell_size;
	if (any(lessThan(pixel, ivec2(0))) || any(greaterThanEqual(cell_position, grid_size))) {
		write_output(vec4(0.0, 0.0, 0.0, 1.0));
		return;
	}

	uint cell_index = uint(cell_position.y * grid_size.x + cell_position.x);
	uvec4 cell = cells[cell_index];
	VisualRecord visual = visuals[cell.x];
	vec4 foreground = unpack_srgb_rgba8(cell.y);
	vec4 background = unpack_srgb_rgba8(cell.z);
	float content_opacity = (cell.w & CELL_BLINK) != 0u ?
		float(layout_data.effects.x) / 65535.0 : 1.0;
	foreground.a *= content_opacity;
	vec4 colour = premultiply(background);
	colour = composite_below_text(colour, pixel);
	ivec2 within_cell = pixel - cell_position * cell_size;
	uint visual_kind = visual.texture.z;

	if (visual_kind != 0u) {
		ivec2 within_visual = within_cell - visual.destination_rect.xy;
		if (all(greaterThanEqual(within_visual, ivec2(0))) &&
		    all(lessThan(within_visual, visual.destination_rect.zw))) {
			uint texture_index = visual.texture.x;
			// Keep nonuniformEXT at each array access. Qualifying a temporary before
			// storing it loses the SPIR-V NonUniform decoration on the access chain.
			if (visual_kind == VISUAL_MASK) {
				ivec2 source_pixel = ivec2(visual.source_rect.xy) +
					within_visual * ivec2(visual.source_rect.zw) /
					visual.destination_rect.zw;
				float coverage = texelFetch(
					resources[nonuniformEXT(texture_index)],
					ivec3(source_pixel, int(visual.texture.y)),
					0
				).r;
				float alpha = adjust_coverage(coverage, layout_data.effects.y) * foreground.a;
				colour = over(vec4(foreground.rgb * alpha, alpha), colour);
			} else if (visual_kind == VISUAL_SUBPIXEL_MASK) {
				ivec2 source_pixel = ivec2(visual.source_rect.xy) +
					within_visual * ivec2(visual.source_rect.zw) /
					visual.destination_rect.zw;
				vec4 coverage = texelFetch(
					resources[nonuniformEXT(texture_index)],
					ivec3(source_pixel, int(visual.texture.y)),
					0
				);
				vec3 component_alpha = adjust_coverage(coverage.rgb, layout_data.effects.y) * foreground.a;
				float alpha = adjust_coverage(coverage.a, layout_data.effects.y) * foreground.a;
				colour.rgb = foreground.rgb * component_alpha +
					colour.rgb * (vec3(1.0) - component_alpha);
				colour.a = alpha + colour.a * (1.0 - alpha);
			} else if (visual_kind == VISUAL_COLOUR) {
				ivec2 source_pixel = ivec2(visual.source_rect.xy) +
					within_visual * ivec2(visual.source_rect.zw) /
					visual.destination_rect.zw;
				vec4 source_colour = texelFetch(
					resources[nonuniformEXT(texture_index)],
					ivec3(source_pixel, int(visual.texture.y)),
					0
				);
				source_colour *= content_opacity;
				colour = over(source_colour, colour);
			} else if (visual_kind == VISUAL_IMAGE) {
				ivec3 texture_extent = textureSize(
					resources[nonuniformEXT(texture_index)],
					0
				);
				vec2 source_position = vec2(visual.source_rect.xy) +
					(vec2(within_visual) + vec2(0.5)) * vec2(visual.source_rect.zw) /
					vec2(visual.destination_rect.zw);
				vec4 source_colour = textureLod(
					resources[nonuniformEXT(texture_index)],
					vec3(source_position / vec2(texture_extent.xy), float(visual.texture.y)),
					0.0
				);
				source_colour *= content_opacity;
				colour = over(source_colour, colour);
			}
		}
	}

	uint underline_style = cell.w & CELL_UNDERLINE_MASK;
	int decoration_thickness = max(1, (cell_size.y + 15) / 16);
	int underline_y = min(cell_size.y - 1, layout_data.font.x + 1);
	int strike_y = max(0, layout_data.font.x - cell_size.y / 3);
	vec4 decoration = unpack_srgb_rgba8(decoration_colours[cell_index]);
	decoration.a *= content_opacity;
	bool decoration_pixel = false;
	if (underline_style == 1u) {
		decoration_pixel = within_cell.y >= underline_y &&
			within_cell.y < underline_y + decoration_thickness;
	} else if (underline_style == 2u) {
		int second_y = min(cell_size.y - 1, underline_y + decoration_thickness + 1);
		decoration_pixel =
			(within_cell.y >= underline_y && within_cell.y < underline_y + decoration_thickness) ||
			(within_cell.y >= second_y && within_cell.y < second_y + decoration_thickness);
	} else if (underline_style == 3u) {
		int wave_y = min(cell_size.y - 1, underline_y + abs((within_cell.x & 3) - 2));
		decoration_pixel = within_cell.y >= wave_y &&
			within_cell.y < wave_y + decoration_thickness;
	} else if (underline_style == 4u) {
		decoration_pixel = (within_cell.x & 1) == 0 && within_cell.y >= underline_y &&
			within_cell.y < underline_y + decoration_thickness;
	} else if (underline_style == 5u) {
		decoration_pixel = (within_cell.x % 5) < 3 && within_cell.y >= underline_y &&
			within_cell.y < underline_y + decoration_thickness;
	} else if (underline_style == 6u) {
		// Renderer-private: the widely spaced dots used to mark a hovered URL.
		// SGR defines underline styles 0-5, so a terminal application cannot
		// ask for this one. The period is measured along the text area rather
		// than within the cell, so the dots stay evenly spaced across cell
		// boundaries at any cell width, and it scales with the line thickness
		// so a small cell still gets a dot.
		int dot_period = decoration_thickness * 3;
		decoration_pixel = (pixel.x % dot_period) < decoration_thickness &&
			within_cell.y >= underline_y &&
			within_cell.y < underline_y + decoration_thickness;
	}
	if ((cell.w & CELL_STRIKETHROUGH) != 0u) {
		decoration_pixel = decoration_pixel ||
			(within_cell.y >= strike_y && within_cell.y < strike_y + decoration_thickness);
	}
	if ((cell.w & CELL_OVERLINE) != 0u) {
		decoration_pixel = decoration_pixel || within_cell.y < decoration_thickness;
	}
	if (decoration_pixel) {
		colour = over(premultiply(decoration), colour);
	}
	if ((layout_data.cursor.z & CURSOR_VISIBLE) != 0u &&
	    all(equal(uvec2(cell_position), layout_data.cursor.xy))) {
		uint cursor_style = layout_data.cursor.z & 0xffu;
		vec4 cursor = unpack_srgb_rgba8(layout_data.cursor.w);
		int underline_thickness = max(2, (cell_size.y + 7) / 8);
		bool cursor_pixel = cursor_style == 0u ? within_cell.x < 2 :
			cursor_style == 2u ? within_cell.y >= cell_size.y - underline_thickness :
			cursor_style == 3u ? (within_cell.x < 1 || within_cell.y < 1 || within_cell.x >= cell_size.x - 1 || within_cell.y >= cell_size.y - 1) : true;
		if (cursor_pixel) {
			float cursor_opacity = float((layout_data.cursor.z >> CURSOR_OPACITY_SHIFT) & CURSOR_OPACITY_MASK) / 65535.0;
			cursor.a *= cursor_opacity;
			colour = over(premultiply(cursor), colour);
		}
	}
	write_output(colour);
}
