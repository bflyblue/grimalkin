#ifndef GRIMALKIN_COLOUR_GLSL
#define GRIMALKIN_COLOUR_GLSL

vec4 unpack_rgba8(uint packed) {
	return vec4(
		float( packed        & 0xffu),
		float((packed >>  8) & 0xffu),
		float((packed >> 16) & 0xffu),
		float((packed >> 24) & 0xffu)
	) / 255.0;
}

vec3 srgb_to_linear(vec3 value) {
	bvec3 low = lessThanEqual(value, vec3(0.04045));
	vec3 linear_low = value / 12.92;
	vec3 linear_high = pow((value + 0.055) / 1.055, vec3(2.4));
	return mix(linear_high, linear_low, low);
}

vec3 linear_to_srgb(vec3 value) {
	value = clamp(value, 0.0, 1.0);
	bvec3 low = lessThanEqual(value, vec3(0.0031308));
	vec3 encoded_low = value * 12.92;
	vec3 encoded_high = 1.055 * pow(value, vec3(1.0 / 2.4)) - 0.055;
	return mix(encoded_high, encoded_low, low);
}

vec4 unpack_srgb_rgba8(uint packed) {
	vec4 encoded = unpack_rgba8(packed);
	return vec4(srgb_to_linear(encoded.rgb), encoded.a);
}

#endif
