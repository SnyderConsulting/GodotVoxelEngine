#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba8) uniform writeonly image2D dest;
layout(set = 0, binding = 1, std140) uniform Params {
    vec4 cam_pos;
    vec4 cam_right;
    vec4 cam_up;
    vec4 cam_forward;
    vec4 params; // x=time, y=width, z=height, w=fov
} u;

const float ICO_RADIUS = 0.55;

float sdf_icosahedron(vec3 p, float r) {
    const float phi = 1.61803398875;
    const float a = 1.0;
    const float b = 1.0 / phi;
    const float c = phi;
    vec3 n[20] = vec3[20](
        normalize(vec3( a,  a,  a)),
        normalize(vec3( a,  a, -a)),
        normalize(vec3( a, -a,  a)),
        normalize(vec3( a, -a, -a)),
        normalize(vec3(-a,  a,  a)),
        normalize(vec3(-a,  a, -a)),
        normalize(vec3(-a, -a,  a)),
        normalize(vec3(-a, -a, -a)),
        normalize(vec3( 0.0,  b,  c)),
        normalize(vec3( 0.0,  b, -c)),
        normalize(vec3( 0.0, -b,  c)),
        normalize(vec3( 0.0, -b, -c)),
        normalize(vec3( b,  c, 0.0)),
        normalize(vec3( b, -c, 0.0)),
        normalize(vec3(-b,  c, 0.0)),
        normalize(vec3(-b, -c, 0.0)),
        normalize(vec3( c, 0.0,  b)),
        normalize(vec3( c, 0.0, -b)),
        normalize(vec3(-c, 0.0,  b)),
        normalize(vec3(-c, 0.0, -b))
    );

    float d = -1e9;
    for (int i = 0; i < 20; i++) {
        d = max(d, dot(p, n[i]));
    }
    return d - r;
}

vec3 estimate_normal(vec3 p) {
    float e = 0.001;
    float dx = sdf_icosahedron(p + vec3(e, 0.0, 0.0), ICO_RADIUS) - sdf_icosahedron(p - vec3(e, 0.0, 0.0), ICO_RADIUS);
    float dy = sdf_icosahedron(p + vec3(0.0, e, 0.0), ICO_RADIUS) - sdf_icosahedron(p - vec3(0.0, e, 0.0), ICO_RADIUS);
    float dz = sdf_icosahedron(p + vec3(0.0, 0.0, e), ICO_RADIUS) - sdf_icosahedron(p - vec3(0.0, 0.0, e), ICO_RADIUS);
    return normalize(vec3(dx, dy, dz));
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
    ndc.y = -ndc.y;
    float aspect = float(width) / float(height);
    float tan_half_fov = tan(u.params.w * 0.5);
    vec3 ro = u.cam_pos.xyz;
    vec3 rd = normalize(
        u.cam_forward.xyz +
        u.cam_right.xyz * (ndc.x * aspect * tan_half_fov) +
        u.cam_up.xyz * (ndc.y * tan_half_fov)
    );

    float t = 0.0;
    vec3 color = vec3(0.12);
    bool hit = false;

    for (int i = 0; i < 160; i++) {
        vec3 p = ro + rd * t;
        float d = sdf_icosahedron(p, ICO_RADIUS);
        if (d < 0.001) {
            hit = true;
            vec3 n = estimate_normal(p);
            float diff = max(dot(n, normalize(vec3(-0.6, -1.0, -0.4))), 0.0);
            color = vec3(0.9, 0.7, 0.4) * (0.2 + diff);
            break;
        }
        t += max(d, 0.01);
        if (t > 8.0) {
            break;
        }
    }

    imageStore(dest, gid, vec4(color, 1.0));
}
