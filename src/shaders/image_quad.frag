#version 450
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_GOOGLE_include_directive : require

#include "colour.glsl"

// Binding 3 of the text descriptor layout, reused so Kitty images sample from
// the same bindless texture array the glyph path already binds.
layout(set = 0, binding = 3) uniform sampler2DArray resources[];

layout(push_constant) uniform ImageQuad {
	ivec4 destination; // x, y, width, height in framebuffer pixels
	uvec4 source;      // x, y, width, height in image pixels
	uvec4 slot;        // texture resource, array layer, manual sRGB output, unused
} quad;

layout(location = 0) out vec4 output_colour;

void main() {
	// The scissor already bounds the draw to the destination, but a placement
	// clipped against the text area can leave the rectangle smaller than the
	// scissor granularity, so the fragment is bounded here too.
	ivec2 pixel = ivec2(gl_FragCoord.xy) - quad.destination.xy;
	if (any(lessThan(pixel, ivec2(0))) || any(greaterThanEqual(pixel, quad.destination.zw))) {
		discard;
	}

	// Keep nonuniformEXT on each resources[...] access. The index is uniform
	// here because it arrives in a push constant, but the project rule is to
	// decorate every access so the pattern stays correct if that ever changes.
	uint texture_index = quad.slot.x;
	ivec3 extent = textureSize(resources[nonuniformEXT(texture_index)], 0);
	vec2 position = vec2(quad.source.xy) +
		(vec2(pixel) + vec2(0.5)) * vec2(quad.source.zw) / vec2(quad.destination.zw);
	vec4 colour = textureLod(
		resources[nonuniformEXT(texture_index)],
		vec3(position / vec2(extent.xy), float(quad.slot.y)),
		0.0
	);

	// Images are uploaded premultiplied, which is what the blend state expects,
	// so only the transfer function is applied here.
	vec3 rgb = colour.rgb;
	if (quad.slot.z != 0u) rgb = linear_to_srgb(rgb);
	output_colour = vec4(rgb, colour.a);
}
