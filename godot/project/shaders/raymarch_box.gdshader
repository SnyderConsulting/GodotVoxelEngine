shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

uniform bool debug_flat = false;
uniform float max_dist = 20.0;
uniform int max_steps = 128;
uniform float surf_eps = 0.002;
uniform vec3 light_dir = vec3(-0.6, -1.0, -0.4);
uniform vec3 light_color = vec3(1.0, 1.0, 1.0);
uniform float ambient = 0.2;
uniform vec3 voxel_color = vec3(0.95, 0.70, 0.40);
uniform vec3 voxel_center = vec3(0.0, 0.0, 0.0);
uniform float voxel_scale = 1.2;
uniform bool voxels_solid = false;

const int VOX_RES = 16;

varying vec3 v_local_pos;

bool voxel_occ(ivec3 cell) {
    vec3 center = (vec3(cell) + vec3(0.5)) / float(VOX_RES) - vec3(0.5);
    return length(center) < 0.35;
}

float sdf_voxels(vec3 p) {
    if (voxels_solid) {
        return length(p - voxel_center) - (0.35 * voxel_scale);
    }

    vec3 local = (p - voxel_center) / voxel_scale;
    vec3 aabb_min = vec3(-0.5);
    vec3 aabb_max = vec3(0.5);
    vec3 d = max(max(aabb_min - local, local - aabb_max), vec3(0.0));
    float outside_dist = length(d) * voxel_scale;
    if (outside_dist > 0.0) {
        return outside_dist;
    }

    vec3 local01 = local + vec3(0.5);
    float cell_size = 1.0 / float(VOX_RES);
    vec3 gv = local01 * float(VOX_RES);
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

vec3 estimate_normal(vec3 p) {
    float e = 0.001;
    float dx = sdf_voxels(p + vec3(e, 0.0, 0.0)) - sdf_voxels(p - vec3(e, 0.0, 0.0));
    float dy = sdf_voxels(p + vec3(0.0, e, 0.0)) - sdf_voxels(p - vec3(0.0, e, 0.0));
    float dz = sdf_voxels(p + vec3(0.0, 0.0, e)) - sdf_voxels(p - vec3(0.0, 0.0, e));
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

        float t = 0.0;
        bool hit = false;
        vec3 p = ro;

        for (int i = 0; i < max_steps; i++) {
            p = ro + rd * t;
            float d = sdf_voxels(p);
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

        vec3 base_color = voxel_color;
        vec3 n = estimate_normal(p);
        vec3 l = normalize(-light_dir);
        float ndotl = max(dot(n, l), 0.0);
        vec3 shade = base_color * (ambient + ndotl * light_color);
        ALBEDO = shade;
    }
}
