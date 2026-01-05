#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba8) uniform writeonly image2D dest;
layout(set = 0, binding = 1, std140) uniform Params {
    vec4 params; // x=time, y=width, z=height
} u;

bool voxel_occ(vec3 p) {
    if (any(lessThan(p, vec3(-0.5))) || any(greaterThan(p, vec3(0.5)))) {
        return false;
    }
    vec3 grid = (p + vec3(0.5)) * 128.0;
    vec3 center = (floor(grid) + vec3(0.5)) / 128.0 - vec3(0.5);
    return length(center) < 0.35;
}

void main() {
    ivec2 gid = ivec2(gl_GlobalInvocationID.xy);
    int width = int(u.params.y);
    int height = int(u.params.z);
    if (gid.x >= width || gid.y >= height) {
        return;
    }

    vec2 uv = (vec2(gid) + vec2(0.5)) / vec2(width, height);
    vec2 ndc = uv * 2.0 - 1.0;
    ndc.x *= float(width) / float(height);

    vec3 ro = vec3(0.0, 0.0, 2.5);
    vec3 rd = normalize(vec3(ndc, -1.6));

    float t = 0.0;
    vec3 color = vec3(0.12);
    bool hit = false;

    for (int i = 0; i < 192; i++) {
        vec3 p = ro + rd * t;
        if (voxel_occ(p)) {
            hit = true;
            vec3 n = normalize(p);
            float diff = max(dot(n, normalize(vec3(-0.6, -1.0, -0.4))), 0.0);
            color = vec3(0.9, 0.7, 0.4) * (0.2 + diff);
            break;
        }
        t += 0.03;
        if (t > 6.0) {
            break;
        }
    }

    imageStore(dest, gid, vec4(color, 1.0));
}
