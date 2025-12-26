#[compute]
#version 450

// 高斯模糊（水平/垂直）

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D src;
layout(set = 0, binding = 1, rgba8) uniform image2D dest;


layout(push_constant, std430) uniform Push {
    int blur_pass;       // 0=水平模糊，1=垂直模糊
    float blur_radius;   // 模糊半径（像素，建议1~3）
    float blur_strength; // 模糊强度（0~1，1=全强度）
} pc;

// 5-Tap高斯核
const float gauss_weights[5] = float[](
    0.2270270270,
    0.1945945946,
    0.1216216216,
    0.0540540541,
    0.0162162162
);

// 安全采样：边缘像素重复采样
vec4 safe_sample(sampler2D tex, vec2 uv, vec2 offset) {
    vec2 tex_size = vec2(textureSize(tex, 0));
    vec2 sample_uv = uv + offset / tex_size;
    // 边界钳制+重复采样
    sample_uv = fract(sample_uv);
    if (sample_uv.x < 0.0) sample_uv.x = 0.0;
    if (sample_uv.x > 1.0) sample_uv.x = 1.0;
    if (sample_uv.y < 0.0) sample_uv.y = 0.0;
    if (sample_uv.y > 1.0) sample_uv.y = 1.0;
    return texture(tex, sample_uv);
}

// 一维高斯模糊（水平/垂直）
vec4 gaussian_blur_1d(vec2 uv) {
    vec2 blur_dir = pc.blur_pass == 0 ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
    float radius = pc.blur_radius * pc.blur_strength;
    
    // 中心采样（权重最高）
    vec4 color = safe_sample(src, uv, vec2(0.0)) * gauss_weights[0];
    float total_weight = gauss_weights[0];

    // 对称采样
    for (int i = 1; i < 5; i++) {
        float offset = float(i) * radius;
        // 正方向采样
        color += safe_sample(src, uv, blur_dir * offset) * gauss_weights[i];
        // 负方向采样
        color += safe_sample(src, uv, -blur_dir * offset) * gauss_weights[i];
        // 累加权重
        total_weight += 2.0 * gauss_weights[i];
    }

    return color / total_weight;
}

void main() {
    ivec2 coords = ivec2(gl_GlobalInvocationID.xy);
    vec2 uv = vec2(coords) / vec2(imageSize(dest));

    // 边界检查
    if (coords.x >= imageSize(dest).x || coords.y >= imageSize(dest).y) {
        imageStore(dest, coords, vec4(0.0));
        return;
    }

    // 执行一维高斯模糊
    vec4 blurred = gaussian_blur_1d(uv);


    imageStore(dest, coords, vec4(blurred));
}