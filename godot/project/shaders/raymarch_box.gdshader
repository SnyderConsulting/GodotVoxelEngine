shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

uniform bool debug_flat = false;
uniform float max_dist = 6.0;
uniform int max_steps = 128;
uniform float surf_eps = 0.002;
uniform float box_size = 0.5;

varying vec3 v_local_pos;

float sdf_box(vec3 p, vec3 b) {
    vec3 d = abs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, max(d.y, d.z)), 0.0);
}

vec3 estimate_normal(vec3 p, vec3 b) {
    float e = 0.001;
    float dx = sdf_box(p + vec3(e, 0.0, 0.0), b) - sdf_box(p - vec3(e, 0.0, 0.0), b);
    float dy = sdf_box(p + vec3(0.0, e, 0.0), b) - sdf_box(p - vec3(0.0, e, 0.0), b);
    float dz = sdf_box(p + vec3(0.0, 0.0, e), b) - sdf_box(p - vec3(0.0, 0.0, e), b);
    return normalize(vec3(dx, dy, dz));
}

void vertex() {
    v_local_pos = VERTEX;
}

void fragment() {
    if (debug_flat) {
        ALBEDO = vec3(1.0, 0.2, 0.2);
    } else {
        vec3 cam_world = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
        vec3 ro = (inverse(MODEL_MATRIX) * vec4(cam_world, 1.0)).xyz;
        vec3 rd = normalize(v_local_pos - ro);
        vec3 b = vec3(box_size);

        float t = 0.0;
        bool hit = false;
        vec3 p = ro;

        for (int i = 0; i < max_steps; i++) {
            p = ro + rd * t;
            float d = sdf_box(p, b);
            if (d < surf_eps) {
                hit = true;
                break;
            }
            t += d;
            if (t > max_dist) {
                break;
            }
        }

        if (!hit) {
            discard;
        }

        vec3 n = estimate_normal(p, b);
        ALBEDO = n * 0.5 + vec3(0.5);
    }
}
