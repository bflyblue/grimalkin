#version 450
#extension GL_GOOGLE_include_directive : require

#include "colour.glsl"

layout(push_constant) uniform ScrollIndicatorLayout {
	ivec4 rect;
	uvec4 style;
} layout_data;

layout(location = 0) out vec4 output_colour;

void main() {
	vec2 size = vec2(layout_data.rect.zw);
	vec2 local = gl_FragCoord.xy - vec2(layout_data.rect.xy);
	vec2 centered = local - size * 0.5;
	float radius = min(size.x, size.y) * 0.5;
	vec2 inner = max(size * 0.5 - vec2(radius), vec2(0.0));
	vec2 q = abs(centered) - inner;
	float distance_to_edge = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
	float coverage = 1.0 - smoothstep(-0.5, 0.5, distance_to_edge);

	vec4 encoded = unpack_rgba8(layout_data.style.x);
	float opacity = float(layout_data.style.y) / 65535.0;
	float alpha = encoded.a * opacity * coverage;
	vec3 rgb = srgb_to_linear(encoded.rgb) * alpha;
	if (layout_data.style.z != 0u) rgb = linear_to_srgb(rgb);
	output_colour = vec4(rgb, alpha);
}
