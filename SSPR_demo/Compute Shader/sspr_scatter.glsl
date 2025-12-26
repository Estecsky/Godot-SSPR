#[compute]
#version 450

//sspr_scatter.glsl

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D depth_tex;
// 1: Hash Buffer (读写, R32UI)
// 存储格式: High 16 bits = Source Y, Low 16 bits = Source X
layout(r32ui, set = 0, binding = 1) uniform restrict uimage2D dest_hash_map;

layout(set = 0, binding = 2, std430) readonly buffer ViewProjMatBuffer {
    mat4 view_proj_mat;     // 抖动视图投影矩阵
    mat4 inv_view_proj_mat;     // 抖动视图投影矩阵的逆矩阵
    mat4 prev_view_proj_mat; // 上一帧的视图投影矩阵
} mat_buffer;

layout(push_constant , std430) uniform Push {
    vec4 water_height; // yzw废弃
} pc;

// 从深度缓冲重建世界坐标
vec3 reconstruct_world_pos(vec2 uv, float depth) {
    vec4 clip_pos = vec4(uv * 2.0 - 1.0, depth, 1.0);
    vec4 world_pos = mat_buffer.inv_view_proj_mat * clip_pos;
    return world_pos.xyz / world_pos.w;
}

void main() {
    ivec2 size = imageSize(dest_hash_map);
    ivec2 id = ivec2(gl_GlobalInvocationID.xy);
    if (id.x >= size.x || id.y >= size.y) {
        return;
    }
    vec2 uv = vec2(id) / vec2(size);

    // 1. 读取深度
    float depth = texture(depth_tex, uv).r;

    // 优化: 极远处的物体不参与反射，节省带宽
    if (depth <= 0.0001 || depth >= 0.97) return; 

    // 2. 重建世界坐标
    vec3 world_pos = reconstruct_world_pos(uv, depth);

    // 优化: 舍弃高度低于水面的像素 (它们不可能被反射)
    float water_height = pc.water_height.x;
    if (world_pos.y < water_height) {
        return;
    }
    // 3. 计算镜像世界坐标
    // 平面反射公式: y' = 2*h - y
    vec3 reflected_world_pos = world_pos;
    reflected_world_pos.y = 2.0 * water_height - world_pos.y;

    // 4. 投影回屏幕空间 (得到反射点在屏幕上的位置)
    vec4 reflected_clip = mat_buffer.view_proj_mat * vec4(reflected_world_pos, 1.0);
    vec3 reflected_ndc = reflected_clip.xyz / reflected_clip.w;
    vec2 reflected_uv = reflected_ndc.xy * 0.5 + 0.5;

    // 检查是否在屏幕范围内
    if (reflected_uv.x < -0.001 || reflected_uv.x > 1.001 || reflected_uv.y < -0.001 || reflected_uv.y > 1.001) {
        return;
    }
    // 写入 Hash Map
    // 将源像素的坐标 (id) 写入到它反射后的位置 (target_pixel)
    // 使用 atomicMax 解决冲突: 
    // 在 Hash 中存储 (SrcY << 16 | SrcX)
    // atomicMax 会保留 Y 值最大的源像素
    // 在Godot的屏幕空间中，Y 值越大意味着屏幕越靠下，也就是离摄像机越近的物体
    // 保证前景遮挡背景

    ivec2 target_pixel = ivec2(reflected_uv * size);
    uint packed_coord = (uint(id.y) << 16) | (uint(id.x) & 0xFFFF);

    // 必须使用 atomic 操作，因为多个像素可能反射到同一点
    imageAtomicMax(dest_hash_map, target_pixel, packed_coord);
}