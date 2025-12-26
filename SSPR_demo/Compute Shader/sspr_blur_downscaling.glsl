#[compute]
#version 450

// sspr_blur_downscaling.glsl
// Dual_kawase模糊

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D src;
layout(set = 0, binding = 1, rgba8) uniform writeonly image2D dst;
layout(push_constant, std430) uniform Push {
    vec2 dst_size; // 目标纹理尺寸
    float offset; // 模糊半径
} pc;

// 纹理坐标（像素→[0,1]）
#define UV ((gl_GlobalInvocationID.xy + vec2(0.5)) / vec2(imageSize(dst)))

#define offset pc.offset
#define half_texel_size (0.5 / pc.dst_size)

void main() {
    ivec2 coords = ivec2(gl_GlobalInvocationID.xy);

    if (coords.x >= pc.dst_size.x || coords.y >= pc.dst_size.y) return;

    vec4 c = texture(src, UV) * 4.0;
    c += texture(src, UV + vec2(-offset - 1.0,-offset - 1.0) * half_texel_size);
    c += texture(src, UV + vec2(-offset - 1.0,offset + 1.0) * half_texel_size);
    c += texture(src, UV + vec2(offset + 1.0,-offset - 1.0) * half_texel_size);
    c += texture(src, UV + vec2(offset + 1.0,offset + 1.0) * half_texel_size);
    imageStore(dst, coords, c * 0.125);
}

