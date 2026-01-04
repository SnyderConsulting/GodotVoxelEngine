shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

uniform sampler3D indirection_tex;
uniform sampler3D atlas_tex;

uniform vec3 cam_origin;
uniform vec3 cam_target;
uniform vec3 cam_debug;
uniform mat3 cam_basis;
uniform float cam_fov = 70.0;
uniform float cam_aspect = 1.7777;

uniform vec3 grid_min;
uniform vec3 grid_max;
uniform ivec3 grid_size;
uniform ivec3 brick_counts;
uniform int brick_size = 8;
uniform int debug_mode = 0;

const int MAX_STEPS = 512;

float sample_voxel(ivec3 voxel) {
	if (voxel.x < 0 || voxel.y < 0 || voxel.z < 0) {
		return 0.0;
	}
	if (voxel.x >= grid_size.x || voxel.y >= grid_size.y || voxel.z >= grid_size.z) {
		return 0.0;
	}
	ivec3 brick = voxel / brick_size;
	float raw_index = texelFetch(indirection_tex, brick, 0).r;
	float max_index = float(brick_counts.x * brick_counts.y * brick_counts.z - 1);
	float brick_index = floor(raw_index * max_index + 0.5);
	if (brick_index < 0.0) {
		return 0.0;
	}
	int brick_i = int(brick_index + 0.5);
	int bricks_xy = brick_counts.x * brick_counts.y;
	ivec3 brick_coords = ivec3(brick_i % brick_counts.x, (brick_i / brick_counts.x) % brick_counts.y, brick_i / bricks_xy);
	ivec3 local = voxel - brick * brick_size;
	ivec3 atlas_voxel = brick_coords * brick_size + local;
	return texelFetch(atlas_tex, atlas_voxel, 0).r;
}

vec3 estimate_normal(ivec3 voxel) {
	float sx1 = sample_voxel(voxel + ivec3(1, 0, 0));
	float sx0 = sample_voxel(voxel + ivec3(-1, 0, 0));
	float sy1 = sample_voxel(voxel + ivec3(0, 1, 0));
	float sy0 = sample_voxel(voxel + ivec3(0, -1, 0));
	float sz1 = sample_voxel(voxel + ivec3(0, 0, 1));
	float sz0 = sample_voxel(voxel + ivec3(0, 0, -1));
	return normalize(vec3(sx1 - sx0, sy1 - sy0, sz1 - sz0));
}

bool intersect_aabb(vec3 ro, vec3 rd, vec3 bmin, vec3 bmax, out float tmin, out float tmax) {
	vec3 inv_dir = 1.0 / rd;
	vec3 t0 = (bmin - ro) * inv_dir;
	vec3 t1 = (bmax - ro) * inv_dir;
	vec3 tsmaller = min(t0, t1);
	vec3 tbigger = max(t0, t1);
	tmin = max(max(tsmaller.x, tsmaller.y), tsmaller.z);
	tmax = min(min(tbigger.x, tbigger.y), tbigger.z);
	return tmax >= max(tmin, 0.0);
}

void fragment() {
	vec2 suv = SCREEN_UV;
	vec3 out_color = vec3(suv, 0.0);
	vec2 uv = UV * 2.0 - 1.0;
	uv.x *= cam_aspect;
	float fov_scale = tan(radians(cam_fov) * 0.5);

	vec3 forward = normalize(cam_target - cam_origin);
	vec3 right = normalize(cross(forward, vec3(0.0, 1.0, 0.0)));
	if (length(right) < 0.001) {
		right = normalize(cross(forward, vec3(0.0, 0.0, 1.0)));
	}
	vec3 up = normalize(cross(right, forward));

	vec3 ray_dir = normalize(uv.x * fov_scale * right - uv.y * fov_scale * up + forward);
	out_color = ray_dir * 0.5 + vec3(0.5);
	vec3 ray_origin = cam_origin;

	float tmin;
	float tmax;
	if (intersect_aabb(ray_origin, ray_dir, grid_min, grid_max, tmin, tmax)) {
		float t = max(tmin, 0.0);
		vec3 pos = ray_origin + ray_dir * t;
		vec3 p = pos - grid_min;

		ivec3 voxel = ivec3(floor(p));
		ivec3 step = ivec3(sign(ray_dir));

		vec3 inv_ray = 1.0 / max(abs(ray_dir), vec3(1e-6));
		vec3 t_delta = abs(inv_ray);
		vec3 next_boundary = vec3(voxel) + vec3(step > ivec3(0));
		vec3 t_max = (next_boundary - p) * inv_ray;

		bool hit = false;
		int steps = 0;
		for (int i = 0; i < MAX_STEPS; i++) {
			if (voxel.x < 0 || voxel.y < 0 || voxel.z < 0 || voxel.x >= grid_size.x || voxel.y >= grid_size.y || voxel.z >= grid_size.z) {
				break;
			}
			float v = sample_voxel(voxel);
			if (v > 0.1) {
				vec3 normal = estimate_normal(voxel);
				vec3 light_dir = normalize(vec3(0.4, 0.7, 0.2));
				float ndotl = max(dot(normal, light_dir), 0.15);
				vec3 hit_color = mix(vec3(0.2, 0.55, 0.85), vec3(0.9, 0.7, 0.35), ndotl);
				out_color = hit_color;
				hit = true;
				steps = i;
				break;
			}

			if (t_max.x < t_max.y) {
				if (t_max.x < t_max.z) {
					voxel.x += step.x;
					t_max.x += t_delta.x;
				} else {
					voxel.z += step.z;
					t_max.z += t_delta.z;
				}
			} else {
				if (t_max.y < t_max.z) {
					voxel.y += step.y;
					t_max.y += t_delta.y;
				} else {
					voxel.z += step.z;
					t_max.z += t_delta.z;
				}
			}
		}

		if (!hit && debug_mode == 1) {
			out_color = ray_dir * 0.5 + vec3(0.5);
		}
	}

	ALBEDO = out_color;
}
