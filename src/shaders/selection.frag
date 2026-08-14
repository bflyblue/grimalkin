#version 450
#extension GL_GOOGLE_include_directive : require

#include "colour.glsl"

layout(set = 0, binding = 0, std430) readonly buffer CellBuffer {
	uvec4 cells[];
};

layout(set = 0, binding = 2, std430) readonly buffer SelectionMask {
	uint selection_words[];
};

layout(push_constant) uniform SelectionLayout {
	uvec4 frame;
	uvec4 grid;
	ivec4 area;
	uvec4 render;
} layout_data;

layout(location = 0) out vec4 output_colour;

const uint STYLE_GLASS = 0u;
const uint STYLE_OUTLINE = 1u;
const uint STYLE_SOLID = 2u;

bool selected(ivec2 cell) {
	if (any(lessThan(cell, ivec2(0))) || any(greaterThanEqual(cell, ivec2(layout_data.grid.xy)))) {
		return false;
	}
	uint index = uint(cell.y) * layout_data.grid.x + uint(cell.x);
	return (selection_words[index >> 5u] & (1u << (index & 31u))) != 0u;
}

void write_colour(vec3 straight_rgb, float alpha) {
	vec3 rgb = straight_rgb * alpha;
	if (layout_data.frame.z != 0u) rgb = linear_to_srgb(rgb);
	output_colour = vec4(rgb, alpha);
}

void main() {
	ivec2 pixel = ivec2(gl_FragCoord.xy) - layout_data.area.xy;
	ivec2 cell_size = ivec2(layout_data.grid.zw);
	ivec2 cell = pixel / cell_size;
	if (any(lessThan(pixel, ivec2(0))) || any(greaterThanEqual(cell, ivec2(layout_data.grid.xy)))) {
		discard;
	}
	ivec2 local = pixel - cell * cell_size;
	bool here = selected(cell);
	bool left = selected(cell + ivec2(-1, 0));
	bool right = selected(cell + ivec2(1, 0));
	bool top = selected(cell + ivec2(0, -1));
	bool bottom = selected(cell + ivec2(0, 1));
	bool top_left = selected(cell + ivec2(-1, -1));
	bool top_right = selected(cell + ivec2(1, -1));
	bool bottom_left = selected(cell + ivec2(-1, 1));
	bool bottom_right = selected(cell + ivec2(1, 1));
	uint style = layout_data.frame.w;

	vec3 background = srgb_to_linear(unpack_rgba8(cells[uint(cell.y) * layout_data.grid.x + uint(cell.x)].z).rgb);
	float luminance = dot(background, vec3(0.2126, 0.7152, 0.0722));
	vec3 bright_cyan = srgb_to_linear(vec3(0.10, 0.72, 1.00));
	vec3 dark_blue = srgb_to_linear(vec3(0.02, 0.20, 0.48));
	vec3 tint = mix(bright_cyan, dark_blue, smoothstep(0.38, 0.78, luminance));

	float scale_x = max(1.0, float(layout_data.render.y) / 65536.0);
	float scale_y = max(1.0, float(layout_data.render.z) / 65536.0);
	float edge_x = max(1.0, scale_x);
	float edge_y = max(1.0, scale_y);
	float bloom_x = max(edge_x, 2.0 * scale_x);
	float bloom_y = max(edge_y, 2.0 * scale_y);
	float radius = max(1.0, 3.0 * min(scale_x, scale_y));

	bool exposed_left = here && !left;
	bool exposed_right = here && !right;
	bool exposed_top = here && !top;
	bool exposed_bottom = here && !bottom;
	float distance_to_edge = 1e6;
	vec2 sample_point = vec2(local) + vec2(0.5);
	if (exposed_left) distance_to_edge = min(distance_to_edge, sample_point.x);
	if (exposed_right) distance_to_edge = min(distance_to_edge, float(cell_size.x) - sample_point.x);
	if (exposed_top) distance_to_edge = min(distance_to_edge, sample_point.y);
	if (exposed_bottom) distance_to_edge = min(distance_to_edge, float(cell_size.y) - sample_point.y);

	// Round only genuinely exposed ribbon corners. Adjacent selected cells keep
	// internal joins square and seamless.
	float rounded_coverage = 1.0;
	float curved_distance = 1e6;
	float convex_signed_distance = -1e6;
	if (exposed_left && exposed_top && !top_left && local.x < radius && local.y < radius) {
		float distance = length(sample_point - vec2(radius)) - radius;
		rounded_coverage = min(rounded_coverage, 1.0 - smoothstep(-1.0, 0.0, distance));
		curved_distance = min(curved_distance, abs(distance));
		convex_signed_distance = max(convex_signed_distance, distance);
	}
	if (exposed_right && exposed_top && !top_right &&
	    float(cell_size.x - 1 - local.x) < radius && local.y < radius) {
		float distance = length(sample_point - vec2(float(cell_size.x) - radius, radius)) - radius;
		rounded_coverage = min(rounded_coverage, 1.0 - smoothstep(-1.0, 0.0, distance));
		curved_distance = min(curved_distance, abs(distance));
		convex_signed_distance = max(convex_signed_distance, distance);
	}
	if (exposed_left && exposed_bottom && !bottom_left &&
	    local.x < radius && float(cell_size.y - 1 - local.y) < radius) {
		float distance = length(sample_point - vec2(radius, float(cell_size.y) - radius)) - radius;
		rounded_coverage = min(rounded_coverage, 1.0 - smoothstep(-1.0, 0.0, distance));
		curved_distance = min(curved_distance, abs(distance));
		convex_signed_distance = max(convex_signed_distance, distance);
	}
	if (exposed_right && exposed_bottom && !bottom_right &&
	    float(cell_size.x - 1 - local.x) < radius && float(cell_size.y - 1 - local.y) < radius) {
		float distance = length(sample_point - vec2(float(cell_size.x) - radius, float(cell_size.y) - radius)) - radius;
		rounded_coverage = min(rounded_coverage, 1.0 - smoothstep(-1.0, 0.0, distance));
		curved_distance = min(curved_distance, abs(distance));
		convex_signed_distance = max(convex_signed_distance, distance);
	}
	distance_to_edge = min(distance_to_edge, curved_distance);

	// A multiline linear selection has concave joins where its partial first
	// and last rows meet fully selected rows. Fill those missing quadrants up
	// to a quarter-circle so the ribbon turns smoothly instead of producing a
	// square notch. These pixels live in an otherwise unselected cell.
	float joined_coverage = 0.0;
	float joined_distance = 1e6;
	float joined_signed_distance = -1e6;
	if (!here && right && bottom && bottom_right &&
	    float(local.x) >= float(cell_size.x) - radius &&
	    float(local.y) >= float(cell_size.y) - radius) {
		float distance = length(sample_point - (vec2(cell_size) - vec2(radius))) - radius;
		joined_coverage = max(joined_coverage, smoothstep(-0.5, 0.5, distance));
		if (abs(distance) < joined_distance) {
			joined_distance = abs(distance);
			joined_signed_distance = distance;
		}
	}
	if (!here && left && bottom && bottom_left &&
	    float(local.x) < radius && float(local.y) >= float(cell_size.y) - radius) {
		float distance = length(sample_point - vec2(radius, float(cell_size.y) - radius)) - radius;
		joined_coverage = max(joined_coverage, smoothstep(-0.5, 0.5, distance));
		if (abs(distance) < joined_distance) {
			joined_distance = abs(distance);
			joined_signed_distance = distance;
		}
	}
	if (!here && right && top && top_right &&
	    float(local.x) >= float(cell_size.x) - radius && float(local.y) < radius) {
		float distance = length(sample_point - vec2(float(cell_size.x) - radius, radius)) - radius;
		joined_coverage = max(joined_coverage, smoothstep(-0.5, 0.5, distance));
		if (abs(distance) < joined_distance) {
			joined_distance = abs(distance);
			joined_signed_distance = distance;
		}
	}
	if (!here && left && top && top_left && local.x < radius && local.y < radius) {
		float distance = length(sample_point - vec2(radius)) - radius;
		joined_coverage = max(joined_coverage, smoothstep(-0.5, 0.5, distance));
		if (abs(distance) < joined_distance) {
			joined_distance = abs(distance);
			joined_signed_distance = distance;
		}
	}

	// Bloom crosses into a directly adjacent unselected cell while all internal
	// cell boundaries remain suppressed.
	float outside_distance = 1e6;
	if (!here && left) outside_distance = min(outside_distance, sample_point.x);
	if (!here && right) outside_distance = min(outside_distance, float(cell_size.x) - sample_point.x);
	if (!here && top) outside_distance = min(outside_distance, sample_point.y);
	if (!here && bottom) outside_distance = min(outside_distance, float(cell_size.y) - sample_point.y);
	if (!here && top_left && !left && !top) outside_distance = min(outside_distance, length(sample_point));
	if (!here && top_right && !right && !top) outside_distance = min(outside_distance, length(sample_point - vec2(cell_size.x, 0)));
	if (!here && bottom_left && !left && !bottom) outside_distance = min(outside_distance, length(sample_point - vec2(0, cell_size.y)));
	if (!here && bottom_right && !right && !bottom) outside_distance = min(outside_distance, length(sample_point - vec2(cell_size)));

	// The bloom around a convex outside corner must measure from the same
	// rounded arc as the bright edge. Cardinal neighbours and the diagonal
	// neighbour otherwise see a square cell edge/vertex and create the hooked
	// double contour visible at selection endpoints.
	float convex_outside_distance = 1e6;
	if (bottom_right && !right && !bottom) {
		convex_outside_distance = min(convex_outside_distance, length(sample_point - (vec2(cell_size) + vec2(radius))) - radius);
	}
	if (bottom && !bottom_left && float(local.x) < radius) {
		convex_outside_distance = min(convex_outside_distance, length(sample_point - vec2(radius, float(cell_size.y) + radius)) - radius);
	}
	if (right && !top_right && float(local.y) < radius) {
		convex_outside_distance = min(convex_outside_distance, length(sample_point - vec2(float(cell_size.x) + radius, radius)) - radius);
	}
	if (bottom_left && !left && !bottom) {
		convex_outside_distance = min(convex_outside_distance, length(sample_point - vec2(-radius, float(cell_size.y) + radius)) - radius);
	}
	if (bottom && !bottom_right && float(local.x) >= float(cell_size.x) - radius) {
		convex_outside_distance = min(convex_outside_distance, length(sample_point - vec2(float(cell_size.x) - radius, float(cell_size.y) + radius)) - radius);
	}
	if (left && !top_left && float(local.y) < radius) {
		convex_outside_distance = min(convex_outside_distance, length(sample_point - vec2(-radius, radius)) - radius);
	}
	if (top_right && !right && !top) {
		convex_outside_distance = min(convex_outside_distance, length(sample_point - vec2(float(cell_size.x) + radius, -radius)) - radius);
	}
	if (top && !top_left && float(local.x) < radius) {
		convex_outside_distance = min(convex_outside_distance, length(sample_point - vec2(radius, -radius)) - radius);
	}
	if (right && !bottom_right && float(local.y) >= float(cell_size.y) - radius) {
		convex_outside_distance = min(convex_outside_distance, length(sample_point - vec2(float(cell_size.x) + radius, float(cell_size.y) - radius)) - radius);
	}
	if (top_left && !left && !top) {
		convex_outside_distance = min(convex_outside_distance, length(sample_point - vec2(-radius)) - radius);
	}
	if (top && !top_right && float(local.x) >= float(cell_size.x) - radius) {
		convex_outside_distance = min(convex_outside_distance, length(sample_point - vec2(float(cell_size.x) - radius, -radius)) - radius);
	}
	if (left && !bottom_left && float(local.y) >= float(cell_size.y) - radius) {
		convex_outside_distance = min(convex_outside_distance, length(sample_point - vec2(-radius, float(cell_size.y) - radius)) - radius);
	}
	if (!here && convex_outside_distance < 1e5) {
		outside_distance = max(0.0, convex_outside_distance);
	}
	// Inside a rounded concave join, the bloom must be an outward offset of the
	// same arc as the bright edge. Using the two straight cardinal distances
	// here creates a visibly squarer, darker contour behind the cyan turn.
	if (!here && joined_distance < 1e5) {
		outside_distance = max(0.0, -joined_signed_distance);
	}

	// One signed contour now drives all three layers. Previously the fill was
	// clipped by rounded_coverage, the bright edge was restricted to selected
	// pixels, and the bloom used a third distance. At convex corners that made
	// the inner shape look rectangular and forced the cyan stroke to turn more
	// tightly than its halo.
	float contour_distance = outside_distance;
	if (here) {
		contour_distance = convex_signed_distance > -1e5
			? convex_signed_distance
			: -distance_to_edge;
	} else if (joined_distance < 1e5) {
		// Positive joined_signed_distance lies in the filled side of a concave
		// turn, hence the sign reversal.
		contour_distance = -joined_signed_distance;
	}

	float fill_coverage = 1.0 - smoothstep(-0.5, 0.5, contour_distance);
	float alpha = 0.0;
	if (style == STYLE_SOLID) alpha = 0.38 * fill_coverage;
	else if (style == STYLE_GLASS) alpha = 0.16 * fill_coverage;

	if (style != STYLE_SOLID) {
		float edge_width = max(edge_x, edge_y);
		float edge_alpha = style == STYLE_OUTLINE ? 0.82 : 0.70;
		float edge_coverage = 1.0 - smoothstep(0.0, edge_width, abs(contour_distance));
		alpha = max(alpha, edge_alpha * edge_coverage);
	}
	if (style != STYLE_SOLID && contour_distance > 0.0 && contour_distance < max(bloom_x, bloom_y)) {
		float bloom_alpha = style == STYLE_OUTLINE ? 0.08 : 0.12;
		alpha = max(alpha, bloom_alpha * (1.0 - smoothstep(0.0, max(bloom_x, bloom_y), contour_distance)));
	}

	if (alpha <= 0.0001) discard;
	write_colour(tint, alpha);
}
