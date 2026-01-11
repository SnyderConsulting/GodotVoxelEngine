shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

void fragment() {
	vec2 uv = FRAGCOORD.xy / VIEWPORT_SIZE;
	ALBEDO = vec3(uv, 0.0);
}