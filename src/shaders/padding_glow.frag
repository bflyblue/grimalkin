#version 450
#extension GL_GOOGLE_include_directive : require

#include "colour.glsl"

layout(set = 0, binding = 0) uniform sampler2D terminal_source;
layout(set = 0, binding = 1) uniform sampler2D background_source;

layout(push_constant) uniform PaddingGlowLayout {
	uvec4 frame;
	ivec4 text;
	uvec4 sampling;
	uvec4 style;
} layout_data;

layout(location = 0) out vec4 output_colour;

const float BACKGROUND_DEPTH = 9.0;
const int BACKGROUND_DEPTH_SAMPLES = 9;
const int BACKGROUND_TANGENT_SAMPLES = 3;
const float TINT_DEPTH = 15.0;
const float TINT_HALF_WIDTH = 6.0;
const int TINT_DEPTH_SAMPLES = 8;
const int TINT_TANGENT_SAMPLES = 7;

vec2 source_uv(vec2 pixel) {
	vec2 text_min = vec2(layout_data.text.xy);
	vec2 text_max = text_min + vec2(layout_data.text.zw) - vec2(1.0);
	vec2 clamped = clamp(pixel, text_min, text_max);
	return (clamped + vec2(0.5)) / vec2(layout_data.frame.xy);
}

vec3 source_pixel(vec2 pixel) {
	return textureLod(terminal_source, source_uv(pixel), 0.0).rgb;
}

vec3 background_pixel(vec2 pixel) {
	return textureLod(background_source, source_uv(pixel), 0.0).rgb;
}

// Sample a deliberately narrow strip just inside one viewport edge: three
// pixels tangentially by nine pixels inward. This follows local background
// cells without smearing adjacent rows or columns into broad colour bands.
// Only the background render is sampled, so glyphs and images cannot leak into
// Background mode.
vec3 narrow_background(
	vec2 edge_pixel,
	vec2 tangent,
	vec2 inward_normal
) {
	vec3 colour = vec3(0.0);
	float weight_sum = 0.0;
	for (int depth_index = 0; depth_index < BACKGROUND_DEPTH_SAMPLES; ++depth_index) {
		float depth = (float(depth_index) + 0.5) *
			BACKGROUND_DEPTH / float(BACKGROUND_DEPTH_SAMPLES);
		float depth_weight = mix(1.0, 0.65, depth / BACKGROUND_DEPTH);
		for (int tangent_index = 0; tangent_index < BACKGROUND_TANGENT_SAMPLES; ++tangent_index) {
			float tangent_offset = float(tangent_index - 1);
			float tangent_weight = tangent_index == 1 ? 1.0 : 0.5;
			float weight = depth_weight * tangent_weight;
			vec2 sample_pixel = edge_pixel +
				inward_normal * depth + tangent * tangent_offset;
			colour += background_pixel(sample_pixel) * weight;
			weight_sum += weight;
		}
	}
	return colour / max(weight_sum, 0.0001);
}

// A narrow tangential, deep inward half-ellipse. Matching full/background
// samples isolate rendered foreground and image energy without reintroducing
// a regular sparse-sampling pattern. The narrow axis strongly favours the
// pixel's corresponding row or column.
vec3 anisotropic_tint(
	vec2 edge_pixel,
	vec2 tangent,
	vec2 inward_normal
) {
	vec3 tint = vec3(0.0);
	float weight_sum = 0.0;
	for (int depth_index = 0; depth_index < TINT_DEPTH_SAMPLES; ++depth_index) {
		float depth = 1.0 + float(depth_index) *
			(TINT_DEPTH - 1.0) / float(TINT_DEPTH_SAMPLES - 1);
		float normalized_depth = depth / TINT_DEPTH;
		for (int tangent_index = 0; tangent_index < TINT_TANGENT_SAMPLES; ++tangent_index) {
			float tangent_offset = float(tangent_index - 3) *
				TINT_HALF_WIDTH / 3.0;
			float normalized_tangent = tangent_offset / TINT_HALF_WIDTH;
			float ellipse = normalized_depth * normalized_depth +
				normalized_tangent * normalized_tangent;
			if (ellipse > 1.0) continue;
			float line_preference = exp(-3.5 * normalized_tangent * normalized_tangent);
			float weight = (0.08 + (1.0 - ellipse) * (1.0 - ellipse)) * line_preference;
			vec2 sample_pixel = edge_pixel +
				inward_normal * depth + tangent * tangent_offset;
			vec3 residual = source_pixel(sample_pixel) -
				background_pixel(sample_pixel);
			tint += max(residual, vec3(0.0)) * weight;
			weight_sum += weight;
		}
	}
	return tint / max(weight_sum, 0.0001);
}

// A five-tap cross around one reflected source position. This keeps the first
// half of the tint band aligned closely to the corresponding row or column,
// while avoiding a single-sample shimmer as the window moves between pixels.
vec3 mirror_tint(
	vec2 edge_pixel,
	vec2 tangent,
	vec2 inward_normal,
	float depth
) {
	vec2 center = edge_pixel + inward_normal * depth;
	vec3 tint = max(source_pixel(center) - background_pixel(center), vec3(0.0)) * 4.0;
	float weight_sum = 4.0;
	for (int direction = -1; direction <= 1; direction += 2) {
		float sign_value = float(direction);
		vec2 tangent_pixel = center + tangent * (0.75 * sign_value);
		vec2 depth_pixel = center + inward_normal * (0.75 * sign_value);
		tint += max(source_pixel(tangent_pixel) - background_pixel(tangent_pixel), vec3(0.0));
		tint += max(source_pixel(depth_pixel) - background_pixel(depth_pixel), vec3(0.0));
		weight_sum += 2.0;
	}
	return tint / weight_sum;
}

float interleaved_gradient_noise(vec2 pixel) {
	return fract(52.9829189 * fract(dot(pixel, vec2(0.06711056, 0.00583715))));
}

void main() {
	ivec2 pixel = ivec2(gl_FragCoord.xy);
	ivec2 frame_size = ivec2(layout_data.frame.xy);
	ivec2 text_min = layout_data.text.xy;
	ivec2 text_max = text_min + layout_data.text.zw;
	ivec2 closest = clamp(pixel, text_min, text_max - ivec2(1));

	bool outside_x = pixel.x < text_min.x || pixel.x >= text_max.x;
	bool outside_y = pixel.y < text_min.y || pixel.y >= text_max.y;
	vec2 inward = vec2(0.0);
	if (pixel.x < text_min.x) inward.x = 1.0;
	else if (pixel.x >= text_max.x) inward.x = -1.0;
	if (pixel.y < text_min.y) inward.y = 1.0;
	else if (pixel.y >= text_max.y) inward.y = -1.0;

	vec2 normalized = vec2(0.0);
	if (pixel.x < text_min.x) {
		normalized.x = float(text_min.x - pixel.x - 1) / float(max(text_min.x - 1, 1));
	} else if (pixel.x >= text_max.x) {
		normalized.x = float(pixel.x - text_max.x) /
			float(max(frame_size.x - text_max.x - 1, 1));
	}
	if (pixel.y < text_min.y) {
		normalized.y = float(text_min.y - pixel.y - 1) / float(max(text_min.y - 1, 1));
	} else if (pixel.y >= text_max.y) {
		normalized.y = float(pixel.y - text_max.y) /
			float(max(frame_size.y - text_max.y - 1, 1));
	}
	normalized = clamp(normalized, vec2(0.0), vec2(1.0));

	float corner_amount = outside_x && outside_y ? min(normalized.x, normalized.y) : 0.0;
	vec2 edge_pixel = vec2(closest);
	vec3 horizontal_background = vec3(0.0);
	vec3 vertical_background = vec3(0.0);
	if (outside_y) {
		horizontal_background = narrow_background(
			edge_pixel,
			vec2(1.0, 0.0),
			vec2(0.0, inward.y)
		);
	}
	if (outside_x) {
		vertical_background = narrow_background(
			edge_pixel,
			vec2(0.0, 1.0),
			vec2(inward.x, 0.0)
		);
	}

	float padding_position = max(normalized.x, normalized.y);
	vec3 background = outside_x ? vertical_background : horizontal_background;
	float corner_mix = 0.5;
	if (outside_x && outside_y) {
		float axis_sum = normalized.x + normalized.y;
		if (axis_sum > 0.0001) {
			float axis_ratio = normalized.x / axis_sum;
			corner_mix = smoothstep(0.0, 1.0, axis_ratio);
		}
		background = mix(horizontal_background, vertical_background, corner_mix);
	}
	vec2 face_normal = normalize(inward);
	vec3 face_background = background_pixel(edge_pixel + face_normal * 2.0);
	background = mix(
		face_background,
		background,
		smoothstep(0.0, 0.24, padding_position)
	);
	float background_brightness = max(background.r, max(background.g, background.b));
	float bright_amount = smoothstep(0.04, 0.35, background_brightness);
	float edge_luminance = mix(0.90, 0.15, bright_amount);
	background *= mix(1.0, edge_luminance, padding_position);

	vec3 colour = background;
	bool tint_mode = layout_data.frame.w == 2u;
	float outer_position = padding_position;
	float tint_envelope = tint_mode ? smoothstep(0.48, 0.5, outer_position) : 0.0;
	if (tint_envelope > 0.0) {
		float mirror_progress = clamp((outer_position - 0.5) / 0.5, 0.0, 1.0);
		float mirror_depth = mix(1.0, TINT_DEPTH, smoothstep(0.0, 1.0, mirror_progress));
		float blur_mix = mirror_progress;
		vec3 horizontal_mirror = vec3(0.0);
		vec3 vertical_mirror = vec3(0.0);
		vec3 horizontal_blur = vec3(0.0);
		vec3 vertical_blur = vec3(0.0);
		if (outside_y) {
			horizontal_mirror = mirror_tint(
				edge_pixel,
				vec2(1.0, 0.0),
				vec2(0.0, inward.y),
				mirror_depth
			);
			horizontal_blur = anisotropic_tint(
				edge_pixel,
				vec2(1.0, 0.0),
				vec2(0.0, inward.y)
			);
		}
		if (outside_x) {
			vertical_mirror = mirror_tint(
				edge_pixel,
				vec2(0.0, 1.0),
				vec2(inward.x, 0.0),
				mirror_depth
			);
			vertical_blur = anisotropic_tint(
				edge_pixel,
				vec2(0.0, 1.0),
				vec2(inward.x, 0.0)
			);
		}
		vec3 mirror = outside_x ? vertical_mirror : horizontal_mirror;
		vec3 blur = outside_x ? vertical_blur : horizontal_blur;
		if (outside_x && outside_y) {
			mirror = mix(horizontal_mirror, vertical_mirror, corner_mix);
			blur = mix(horizontal_blur, vertical_blur, corner_mix);
			// Corners combine two reflected edges. Reduce their overlap smoothly
			// rather than forming a bright diagonal seam.
			float corner_attenuation = mix(
				1.0,
				0.72,
				smoothstep(0.0, 1.0, corner_amount)
			);
			mirror *= corner_attenuation;
			blur *= corner_attenuation;
		}
		vec3 tint = mix(mirror, blur, blur_mix);
		float tint_opacity = mix(0.25, 0.10, mirror_progress);
		colour = clamp(background + tint * (tint_opacity * tint_envelope), 0.0, 1.0);
	}

	vec3 encoded = linear_to_srgb(colour);
	float dither = (interleaved_gradient_noise(gl_FragCoord.xy) - 0.5) / 255.0;
	encoded = clamp(encoded + vec3(dither), 0.0, 1.0);
	colour = layout_data.frame.z != 0u ? encoded : srgb_to_linear(encoded);
	output_colour = vec4(colour, 1.0);
}
