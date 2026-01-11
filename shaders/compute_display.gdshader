shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

uniform sampler2D compute_tex;

void fragment() {
    vec3 color = texture(compute_tex, UV).rgb;
    ALBEDO = color;
}
