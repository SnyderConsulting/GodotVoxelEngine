shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

uniform bool debug_flat = false;
uniform float max_dist = 6.0;
uniform int max_steps = 128;
uniform float surf_eps = 0.002;
uniform float box_size = 0.5;
uniform vec3 sphere_center = vec3(0.0, 0.3, 0.0);
uniform float sphere_radius = 0.35;
uniform float ground_height = -0.5;
uniform vec3 light_dir = vec3(-0.6, -1.0, -0.4);
uniform vec3 light_color = vec3(1.0, 1.0, 1.0);
uniform float ambient = 0.2;
uniform vec3 box_color = vec3(0.70, 0.70, 0.95);
uniform vec3 sphere_color = vec3(0.55, 0.95, 0.95);
uniform vec3 ground_color = vec3(0.55, 0.95, 0.55);
uniform vec3 voxel_color = vec3(0.95, 0.70, 0.40);
uniform bool voxels_enabled = true;
uniform vec3 voxel_center = vec3(0.0, 0.0, -0.2);
uniform float voxel_scale = 0.6;

const int VOX_RES = 16;

varying vec3 v_local_pos;

float sdf_box(vec3 p, vec3 b) {
    vec3 d = abs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, max(d.y, d.z)), 0.0);
}

float sdf_sphere(vec3 p, float r) {
    return length(p) - r;
}

float sdf_ground(vec3 p, float height) {
    return p.y - height;
}

float sdf_scene(vec3 p, vec3 b) {
    float ground = sdf_ground(p, ground_height);
    float sphere = sdf_sphere(p - sphere_center, sphere_radius);
    float box = sdf_box(p, b);
    return min(ground, min(sphere, box));
}

vec3 estimate_normal(vec3 p, vec3 b) {
    float e = 0.001;
    float dx = sdf_scene(p + vec3(e, 0.0, 0.0), b) - sdf_scene(p - vec3(e, 0.0, 0.0), b);
    float dy = sdf_scene(p + vec3(0.0, e, 0.0), b) - sdf_scene(p - vec3(0.0, e, 0.0), b);
    float dz = sdf_scene(p + vec3(0.0, 0.0, e), b) - sdf_scene(p - vec3(0.0, 0.0, e), b);
    return normalize(vec3(dx, dy, dz));
}

bool voxel_occ(ivec3 cell) {
    vec3 center = (vec3(cell) + vec3(0.5)) / float(VOX_RES) - vec3(0.5);
    return length(center) < 0.35;
}

float sdf_voxels(vec3 p) {
    vec3 local = (p - voxel_center) / voxel_scale + vec3(0.5);
    if (any(lessThan(local, vec3(0.0))) || any(greaterThan(local, vec3(1.0)))) {
        return 1e6;
    }

    float cell_size = 1.0 / float(VOX_RES);
    vec3 gv = local * float(VOX_RES);
    ivec3 base = ivec3(floor(gv));
    float min_d = 1e6;

    for (int z = -1; z <= 1; z++) {
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                ivec3 cell = base + ivec3(x, y, z);
                if (cell.x < 0 || cell.y < 0 || cell.z < 0) {
                    continue;
                }
                if (cell.x >= VOX_RES || cell.y >= VOX_RES || cell.z >= VOX_RES) {
                    continue;
                }
                if (!voxel_occ(cell)) {
                    continue;
                }

                vec3 cell_min = (vec3(cell) * cell_size - vec3(0.5)) * voxel_scale + voxel_center;
                vec3 cell_max = cell_min + vec3(cell_size) * voxel_scale;
                vec3 d = max(max(cell_min - p, p - cell_max), vec3(0.0));
                float dist = length(d);
                if (dist < min_d) {
                    min_d = dist;
                }
            }
        }
    }

    return min_d;
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
            float d = sdf_scene(p, b);
            if (voxels_enabled) {
                d = min(d, sdf_voxels(p));
            }
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

        float d_ground = sdf_ground(p, ground_height);
        float d_sphere = sdf_sphere(p - sphere_center, sphere_radius);
        float d_box = sdf_box(p, b);
        float d_voxels = voxels_enabled ? sdf_voxels(p) : 1e6;
        vec3 base_color = box_color;
        float min_d = d_box;
        if (d_sphere < min_d) {
            min_d = d_sphere;
            base_color = sphere_color;
        }
        if (d_ground < min_d) {
            min_d = d_ground;
            base_color = ground_color;
        }
        if (d_voxels < min_d) {
            min_d = d_voxels;
            base_color = voxel_color;
        }

        vec3 n = estimate_normal(p, b);
        vec3 l = normalize(-light_dir);
        float ndotl = max(dot(n, l), 0.0);
        vec3 shade = base_color * (ambient + ndotl * light_color);
        ALBEDO = shade;
    }
}
