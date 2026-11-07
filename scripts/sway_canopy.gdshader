shader_type spatial;
render_mode diffuse_lambert, specular_disabled;

// Stage A background-canopy sway: the whole canopy leans a
// degree or two on a slow wander (dominant period ~14 s),
// phased by world position so no two trees move together.
// GPU only - TIME drives it, no script touches a tree per
// frame. Displacement grows with local height in the unit
// canopy sphere (base still, crown moving), which reads as a
// lean about the canopy's base rather than a slide.
uniform vec4 albedo : source_color = vec4(0.24, 0.44, 0.19, 1.0);
uniform float sway_amp = 0.045;

void vertex() {
	vec4 wp = MODEL_MATRIX * vec4(VERTEX, 1.0);
	float phase = wp.x * 0.37 + wp.z * 0.53;
	float h = clamp(VERTEX.y * 0.5 + 0.5, 0.0, 1.0);
	vec2 drift = vec2(
		sin(TIME * 0.45 + phase) + 0.5 * sin(TIME * 0.83 + phase * 1.7),
		cos(TIME * 0.34 + phase * 1.3) + 0.5 * sin(TIME * 0.61 + phase * 0.6));
	VERTEX.xz += drift * sway_amp * h;
}

void fragment() {
	ALBEDO = albedo.rgb;
}
