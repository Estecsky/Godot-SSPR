shader_type spatial;
render_mode unshaded , depth_draw_opaque;  

// 相机射线方法重建世界空间位置的shader
// 参考:https://zhuanlan.zhihu.com/p/648793922

uniform vec3  camera_pos;
uniform vec3  top_left;
uniform vec3  x_extent;
uniform vec3  y_extent;
uniform float z_near_inv;  // == 1/near
uniform sampler2D DEPTH_TEXTURE : hint_depth_texture,repeat_disable,filter_nearest;

vec4 Get_zBufferParam(float near ,float far)
{
	vec4 zBufferParam = vec4((far - near)/near,
					1.0,
					(far - near)/(near*far),
					1.0/far);
	return zBufferParam;
}

// Z buffer to linear depth.
// Does NOT correctly handle oblique view frustums.
// Does NOT work with orthographic projection.
// zBufferParam = { (f-n)/n, 1, (f-n)/n*f, 1/f }
float LinearEyeDepth(float depth, vec4 zBufferParam)
{
    return 1.0 / (zBufferParam.z * depth + zBufferParam.w);
}

// Z buffer to linear 0..1 depth (0 at camera position, 1 at far plane).
// Does NOT work with orthographic projections.
// Does NOT correctly handle oblique view frustums.
// zBufferParam = { (f-n)/n, 1, (f-n)/n*f, 1/f }
float Linear01Depth(float depth, vec4 zBufferParam)
{
    return 1.0 / (zBufferParam.x * depth + zBufferParam.y);
}

// 根据屏幕 UV + 线性深度 重建世界坐标
vec3 reconstruct_world_pos(vec2 uv, float depth){
	// Godot 的 SCREEN_UV 是 [0..1]，直接使用
	vec3 ray = top_left + x_extent * uv.x + y_extent * uv.y;
	return camera_pos + ray * (depth * z_near_inv);
}

void fragment(){
	// 1. 取zbuffer深度（线性 0..1）
	float depth = texture(DEPTH_TEXTURE, SCREEN_UV).r;
	
	//ALBEDO = vec3(depth);
	float near = 0.05;          // 与脚本保持一致
	float far  = 4000.0;       // 可改成项目设置
	
	vec4 zBufferParam = Get_zBufferParam(near,far);
	// 2. 还原成线性 Eye Depth（near..far）
	depth = LinearEyeDepth(depth,zBufferParam);

	// 3. 重建
	vec3 wpos = reconstruct_world_pos(SCREEN_UV, depth);

	 //4. 随便可视化一下：把世界坐标当颜色输出
	ALBEDO = vec3(clamp(depth/100.0,.0,1.0)) ; 
}
