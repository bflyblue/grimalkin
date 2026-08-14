#version 450
#extension GL_GOOGLE_include_directive : require

#include "colour.glsl"

layout(set = 0, binding = 0, std430) readonly buffer CellBuffer {
	uvec4 cells[];
};

layout(push_constant) uniform TextLayout {
	uvec4 grid;
	ivec4 font;
	uvec4 cursor;
	uvec4 effects;
} layout_data;

layout(location = 0) out vec4 output_colour;

void main() {
	ivec2 pixel = ivec2(gl_FragCoord.xy) - layout_data.font.yz;
	ivec2 cell_size = ivec2(layout_data.grid.zw);
	ivec2 grid_size = ivec2(layout_data.grid.xy);
	ivec2 cell_position = pixel / cell_size;
	if (any(lessThan(pixel, ivec2(0))) || any(greaterThanEqual(cell_position, grid_size))) {
		output_colour = vec4(0.0, 0.0, 0.0, 1.0);
		return;
	}
	uint cell_index = uint(cell_position.y * grid_size.x + cell_position.x);
	vec4 encoded = unpack_rgba8(cells[cell_index].z);
	output_colour = vec4(srgb_to_linear(encoded.rgb) * encoded.a, 1.0);
}
