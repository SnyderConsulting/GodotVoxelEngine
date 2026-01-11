shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

uniform sampler3D sanity_tex;
uniform float slice = 0.5;

void fragment() {
	vec3 color = texture(sanity_tex, vec3(UV, slice)).rgb;
	ALBEDO = color;
}