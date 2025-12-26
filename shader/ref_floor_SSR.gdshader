shader_type spatial;
render_mode  depth_draw_always,cull_back, diffuse_burley, specular_schlick_ggx;

// SSR 地板 shader
// 参考:https://github.com/JyarlJung/GodotWaterShader

const float z_near = 0.05;
const float z_far = 4000.0;
uniform sampler2D depth_texture : hint_depth_texture,filter_nearest;
uniform sampler2D screen_texture : hint_screen_texture,filter_nearest;

uniform vec4 albedo : source_color;
uniform sampler2D texture_albedo : source_color, filter_linear_mipmap, repeat_enable;

//uniform float point_size : hint_range(0.1, 128.0, 0.1);

uniform float roughness : hint_range(0.0, 1.0);
//uniform sampler2D texture_metallic : hint_default_white, filter_linear_mipmap, repeat_enable;
//uniform vec4 metallic_texture_channel;
//uniform sampler2D texture_roughness : hint_roughness_r, filter_linear_mipmap, repeat_enable;

uniform float specular : hint_range(0.0, 1.0, 0.01);
uniform float metallic : hint_range(0.0, 1.0, 0.01);

uniform sampler2D texture_normal : hint_roughness_normal, filter_linear_mipmap, repeat_enable;
uniform float normal_scale : hint_range(-16.0, 16.0);

group_uniforms SSRSetting;
uniform int ssr_max_travel = 24;
//uniform float step_pixel_size = 6.0;
uniform float depth_tolerance = 0.2;

vec3 uv_to_view(vec2 uv, float depth, mat4 inv_proj_m)
{
	vec4 position_ndc = vec4((uv * 2.0) - 1.0, depth, 1.0);
	vec4 view_position = inv_proj_m * position_ndc;
	return view_position.xyz / view_position.w;
}
vec3 view_to_uv(vec3 position_view_space, mat4 proj_m, out float w)
{
	vec4 position_clip_space = proj_m * vec4(position_view_space.xyz, 1.0);
	vec3 position_ndc = position_clip_space.xyz / position_clip_space.w;
	w = position_clip_space.w;
	return vec3(position_ndc.xy * 0.5 + 0.5, position_ndc.z);
}

vec4 get_depth_tested_color(vec4 pos, vec4 advance, vec2 viewport_size, mat4 inv_mat){
	vec2 pixel_size = 1.0 / viewport_size;
	vec2 init_pos = pos.xy;
	float z_from = pos.z / pos.w;
	float z_to = z_from;
	vec2 uv;
	float depth;
	for(int i = 0; i < ssr_max_travel; i++)
	{
		pos += advance;
		uv = (pos.xy - 0.5) * pixel_size;
		depth = uv_to_view(uv,texture(depth_texture,uv).r, inv_mat).z;

		z_from = z_to;
		z_to = pos.z / pos.w;

		if(depth > z_to && depth <= max(z_to, z_from) + depth_tolerance && -depth < z_far * 1.0)
		{
			if (any(bvec4(lessThan(pos.xy, vec2(1.0, 1.0)), greaterThan(pos.xy,viewport_size))) == false) {
			return vec4(texture(screen_texture, (pos.xy-0.5) * pixel_size).rgb,1.0);
			}
		}
	}
	return vec4(0.0);
}

// Unity 使用的 Z buffer 参数计算
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

varying vec4 world_pos;

void vertex() {
	world_pos = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
}

void fragment() {
	vec2 base_uv = UV;
	mat3 tbn = mat3(TANGENT,BINORMAL,NORMAL);


	vec3 normal_map = texture(texture_normal,UV).xyz * 2.0 - 1.0;
	vec3 normal = normalize(tbn * normal_map);

	vec4 albedo_tex = texture(texture_albedo, base_uv);

	vec2 pixel_size = 1.0 / VIEWPORT_SIZE;
	vec3 vertex = VERTEX;
	float sample_depth = texture(depth_texture,SCREEN_UV).r;

	//Calculate SSR line advence
	vec3 view_dir = normalize(vertex);
	vec3 ray_dir = normalize(reflect(view_dir,normal));

	float ray_len = (vertex.z + ray_dir.z * z_far) > - z_near ? (-z_near - vertex.z) / ray_dir.z : z_far;
	vec3 ray_end = vertex + ray_dir * ray_len;

	float w_begin;
	vec3 vp_line_begin = view_to_uv(vertex,PROJECTION_MATRIX,w_begin);
	float w_end;
	vec3 vp_line_end = view_to_uv(ray_end,PROJECTION_MATRIX,w_end);
	vec2 vp_line_dir = vp_line_end.xy - vp_line_begin.xy;

	w_begin = 1.0 / w_begin;
	w_end = 1.0 / w_end;

	float z_begin = vertex.z * w_begin;
	float z_end = ray_end.z * w_end;

	vec2 line_begin = vp_line_begin.xy / pixel_size;
	vec2 line_dir = vp_line_dir / pixel_size;
	float z_dir = z_end - z_begin;
	float w_dir = w_end - w_begin;

	float scale_max_x = min(1.0, 0.99 * (1.0 - vp_line_begin.x) / max(1e-5, vp_line_dir.x));
	float scale_max_y = min(1.0, 0.99 * (1.0 - vp_line_begin.y) / max(1e-5, vp_line_dir.y));
	float scale_min_x = min(1.0, 0.99 * vp_line_begin.x / max(1e-5, -vp_line_dir.x));
	float scale_min_y = min(1.0, 0.99 * vp_line_begin.y / max(1e-5, -vp_line_dir.y));
	float line_clip = min(scale_max_x,scale_max_y) * min(scale_min_x,scale_min_y);

	line_dir *= line_clip;
	z_dir *= line_clip;
	w_dir *= line_clip;

	float line_length = length(line_dir);
	//vec4 zbuffer_param = Get_zBufferParam(z_near,z_far);

	float dist = length(CAMERA_POSITION_WORLD - world_pos.xyz);
	float linear_dist =clamp(dist/200.0, 0.0,1.0);

	float distance_factor = linear_dist;
	// 按距离动态调整步长（近处小步长，远处大步长）
	float dynamic_step_size = mix(2.0, 8.0, distance_factor);

	float advance_angle_adj = 1.0 / max(abs(normalize(line_dir).x), abs(normalize(line_dir).y));
	//float step_size = step_pixel_size / length(line_dir);
	//vec4 line_advance = vec4(line_dir, z_dir, w_dir) * advance_angle_adj * step_size;
	vec4 line_advance = vec4(line_dir, z_dir, w_dir) * advance_angle_adj * (dynamic_step_size / line_length);
	vec4 init_pos = vec4(line_begin, z_begin, w_begin);	//calculated SSR line advence

	//get SSR
	vec4 reflect_color;
	float reflect_amount;
	if (ray_dir.z > 0.0 || ray_len < 0.1){
		reflect_color = vec4(0.0);
		reflect_amount = 0.0;
	}
	else{
		reflect_color = get_depth_tested_color(init_pos, line_advance, VIEWPORT_SIZE, INV_PROJECTION_MATRIX);
		reflect_amount = reflect_color.a * pow(1.0-dot(normal,VIEW),3.0);
	}

	ALBEDO = albedo.rgb * albedo_tex.rgb ;

	METALLIC = albedo_tex.r * metallic;
	EMISSION = mix(vec3(0.0), reflect_color.rgb, reflect_amount);
	SPECULAR = specular;

	//EMISSION = vec3(distance_factor);
	ROUGHNESS = roughness;

	NORMAL = normal;
}
