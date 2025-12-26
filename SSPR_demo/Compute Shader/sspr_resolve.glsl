#[compute]
#version 450

//sspr_resolve.glsl

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// 0: 场景颜色 (当前帧)
layout(set = 0, binding = 0) uniform sampler2D source_color;
// 1: Hash Map (由 Scatter 生成)
layout(r32ui, set = 0, binding = 1) uniform restrict readonly uimage2D source_hash_map;
// 2: 最终输出 (写入到当前帧的反射纹理,邻域搜索填补空洞)
layout(rgba8, set = 0, binding = 2) uniform restrict image2D dest_reflection;


void main() {
    ivec2 id = ivec2(gl_GlobalInvocationID.xy);
    vec2 size = imageSize(dest_reflection);

    if (id.x >= int(size.x) || id.y >= int(size.y)) return;

    // 邻域搜索填补空洞 ---
    uint best_packed = 0u;
    float min_dist = 99999.0;
    // 搜索 8 个邻居
    // 九个：(0,0), (-1,0), (1,0), (0,-1), (0,1) ,(1,1), (-1,1), (1,-1), (-1,-1)
    ivec2 offsets[9] = ivec2[](ivec2(0,0), ivec2(1,0), ivec2(-1,0), ivec2(0,1), ivec2(0,-1), ivec2(1,1), ivec2(-1,1), ivec2(1,-1), ivec2(-1,-1));

    for(int i=0; i<9; i++) {
        ivec2 sample_pos = id + offsets[i];
        // 边界检查
        if(sample_pos.x < 0 || sample_pos.y < 0 || sample_pos.x >= size.x || sample_pos.y >= size.y) continue;
        
        uint val = imageLoad(source_hash_map, sample_pos).r;
        if (val != 0u) {
            // 简单的“最近优先”策略：
            best_packed = val; 
            break; // 找到一个就停止
        }
    }

    // 读取 Hash
    // best_packed = imageLoad(source_hash_map, id).r;

    vec4 result_color = vec4(0.0);
    bool has_data = best_packed != 0u;

    if (has_data) {
        // 2. 解码源 UV
        uint src_y = best_packed >> 16;
        uint src_x = best_packed & 0xFFFF;
        vec2 src_uv = (vec2(src_x, src_y) + 0.5) / size;

        // 采样当前帧颜色
        result_color = texture(source_color, src_uv);

        // 边缘 Fade (Vignette)
        // 让屏幕边缘的反射淡出，避免硬切
        float fade_x = smoothstep(0.0, 0.1, src_uv.x) * (1.0 - smoothstep(0.9, 1.0, src_uv.x));
        float fade_y = smoothstep(0.0, 0.1, src_uv.y) * (1.0 - smoothstep(0.9, 1.0, src_uv.y));
        result_color.a *= fade_y * fade_x;
    }

    imageStore(dest_reflection, id, result_color);
}
