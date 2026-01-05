#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba8) uniform writeonly image2D out_image;

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(out_image);
    if (pos.x >= size.x || pos.y >= size.y) {
        return;
    }

    vec2 uv = (vec2(pos) + 0.5) / vec2(size);
    float grid = step(0.98, fract(uv.x * 8.0)) * 0.2 + step(0.98, fract(uv.y * 8.0)) * 0.2;
    vec3 color = vec3(uv, 0.35 + grid);
    imageStore(out_image, pos, vec4(color, 1.0));
}
