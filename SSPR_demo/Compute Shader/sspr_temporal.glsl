#[compute]
#version 450

// sspr_temporal.glsl

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D current;
layout(set = 0, binding = 1) uniform sampler2D history;
layout(set = 0, binding = 2) uniform sampler2D depth_tex;

// 视图投影矩阵
layout(set = 0, binding = 3, std430) readonly buffer ViewProjMatBuffer {
    mat4 view_proj_mat;         // 带抖动的VP（世界→裁剪空间）
    mat4 inv_view_proj_mat;     // 带抖动VP的逆（裁剪→世界空间）
    mat4 prev_view_proj_mat;    // 上一帧无抖动VP（世界→裁剪空间）
} data_buffer;

// 输出结果（rgba16f）
layout(set = 0, binding = 4, rgba8) uniform image2D result;

// Push Constant（混合系数、裁剪半径、当前抖动）
layout(push_constant, std430) uniform Push {
    float blend;                // 历史帧混合系数
    float neighbor_clamp_radius;// 邻域裁剪半径（像素）
    float jitter_current_x;     // 当前帧抖动X
    float jitter_current_y;     // 当前帧抖动Y
} pc;

// 屏幕纹理坐标（像素→[0,1]）
#define UV_RAW ((gl_GlobalInvocationID.xy) / vec2(imageSize(result)))
// 像素尺寸（[0,1]空间的单像素大小）
#define PIXEL_SIZE (1.0 / vec2(imageSize(result)))
// 修正抖动后的有效UV（抵消当前帧抖动影响）
#define UV (UV_RAW - vec2(pc.jitter_current_x, pc.jitter_current_y))

// 深度反投影：NDC→世界空间
vec3 ndc_to_world(vec2 uv, float depth) {
    // 构造NDC坐标
    vec4 ndc = vec4(uv * 2.0 - 1.0, depth, 1.0);
    // 逆VP矩阵转换到世界空间
    vec4 world = data_buffer.inv_view_proj_mat * ndc;
    return world.xyz / world.w;
}

// 重投影：世界空间→上一帧纹理坐标
vec2 world_to_prev_uv(vec3 world_pos) {
    // 上一帧VP矩阵转换到裁剪空间
    vec4 prev_clip = data_buffer.prev_view_proj_mat * vec4(world_pos, 1.0);
    // 透视除法→NDC
    vec2 prev_ndc = prev_clip.xy / prev_clip.w;
    // NDC→纹理坐标[0,1]
    vec2 prev_uv = (prev_ndc + 1.0) * 0.5;

    return prev_uv;
}

// 邻域裁剪：限制历史颜色在当前帧邻域颜色范围内
vec4 neighbor_clamp(vec4 history_color, vec2 uv) {
    // 采样当前帧邻域（4方向+中心）
    vec2 offsets[] = vec2[](
        vec2(0, 0),
        vec2(-pc.neighbor_clamp_radius, 0),
        vec2(pc.neighbor_clamp_radius, 0),
        vec2(0, -pc.neighbor_clamp_radius),
        vec2(0, pc.neighbor_clamp_radius)
    );
    
    vec4 min_color = vec4(1e3);
    vec4 max_color = vec4(-1e3);
    for (int i = 0; i < 5; i++) {
        vec2 sample_uv = uv + offsets[i] * PIXEL_SIZE;
        vec4 sample_color = texture(current, sample_uv);
        min_color = min(min_color, sample_color);
        max_color = max(max_color, sample_color);
    }
    
    // 裁剪历史颜色到[min, max]范围
    return clamp(history_color, min_color, max_color);
}

// 指数平滑混合：当前帧 + 历史帧
vec4 taa_blend(vec4 current_color, vec4 history_color) {
    // 邻域裁剪修正历史颜色
    vec4 clamped_history = neighbor_clamp(history_color, UV);
    // 指数平滑混合（pc.blend越小，历史帧权重越高）
    return mix(clamped_history, current_color, pc.blend);
}

void main() {
    ivec2 coords = ivec2(gl_GlobalInvocationID.xy);
    // 边界检查（避免越界采样）
    if (coords.x >= imageSize(result).x || coords.y >= imageSize(result).y) {
        imageStore(result, coords, vec4(0, 0, 0, 1));
        return;
    }
    
    // 1. 采样当前帧颜色和深度
    vec4 current_color = texture(current, UV);
    float depth = texture(depth_tex, UV).r;
    
    // 2. 深度反投影到世界空间
    vec3 world_pos = ndc_to_world(UV, depth);
    
    // 3. 重投影到上一帧纹理坐标
    vec2 prev_uv = world_to_prev_uv(world_pos);
    
    // 4. 采样历史帧（边界检查：超出屏幕则用当前颜色）
    vec4 history_color = current_color;
    if (prev_uv.x >= 0.0 && prev_uv.x <= 1.0 && prev_uv.y >= 0.0 && prev_uv.y <= 1.0) {
        history_color = texture(history, prev_uv);
    }
    
    // 5. TAA混合（邻域裁剪+指数平滑）
    vec4 final_color = taa_blend(current_color, history_color);

    // 6. 输出结果
    imageStore(result, coords, final_color);
}

