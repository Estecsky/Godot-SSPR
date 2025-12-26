#[compute]
#version 450

// 纹理拷贝Compute Shader

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D src_tex;
layout(set = 0, binding = 1, rgba8) uniform writeonly image2D dst_img;

#define UV ((gl_GlobalInvocationID.xy) / vec2(imageSize(dst_img)))
#define img_size vec2(imageSize(dst_img))

layout(push_constant, std430) uniform Push {
    vec2 dst_size;
} pc;

void main() {
    ivec2 coords = ivec2(gl_GlobalInvocationID.xy);

    if (coords.x >= int(img_size.x) || coords.y >= int(img_size.y)) {
        return;
    }

    vec4 color = texture(src_tex, UV);
    imageStore(dst_img, coords, color);
}