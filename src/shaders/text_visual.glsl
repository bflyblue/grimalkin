#ifndef GRIMALKIN_TEXT_VISUAL_GLSL
#define GRIMALKIN_TEXT_VISUAL_GLSL

struct VisualRecord {
	uvec4 source_rect;
	ivec4 destination_rect;
	uvec4 texture; // texture index, array layer, visual kind, flags
};

const uint VISUAL_MASK = 1u;
const uint VISUAL_COLOUR = 2u;
const uint VISUAL_IMAGE = 3u;
const uint VISUAL_SUBPIXEL_MASK = 4u;

float adjust_coverage(float coverage, uint contrast) {
	if (contrast == 0u) return coverage;
	float exponent = contrast == 1u ? 1.40 : contrast == 2u ? 1.80 : 2.20;
	return pow(coverage, exponent);
}

vec3 adjust_coverage(vec3 coverage, uint contrast) {
	if (contrast == 0u) return coverage;
	float exponent = contrast == 1u ? 1.40 : contrast == 2u ? 1.80 : 2.20;
	return pow(coverage, vec3(exponent));
}

#endif
