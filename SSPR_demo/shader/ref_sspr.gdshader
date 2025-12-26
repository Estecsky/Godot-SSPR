shader_type spatial;
render_mode  depth_draw_never,cull_back, diffuse_burley, specular_schlick_ggx;

const float z_near = 0.05;
const float z_far = 4000.0;
uniform sampler2D depth_texture : hint_depth_texture,filter_nearest,repeat_disable;
uniform sampler2D screen_texture : hint_screen_texture,filter_nearest,repeat_disable;

uniform vec4 albedo : source_color;
uniform sampler2D texture_albedo : source_color, filter_linear_mipmap, repeat_enable;

global uniform sampler2D SSPR_Reflection :source_color,filter_linear,repeat_disable;

uniform float roughness : hint_range(0.0, 1.0);

uniform float specular : hint_range(0.0, 1.0, 0.01);
uniform float metallic : hint_range(0.0, 1.0, 0.01);
uniform float step_params : hint_range(0.0, 1.0, 0.001) = 0.0;

uniform sampler2D texture_normal : hint_roughness_normal, filter_linear_mipmap, repeat_enable;
uniform float normal_scale : hint_range(-16.0, 16.0);

//uniform float stretch_threshlod : hint_range(0.0, 1.0, 0.001) = 0.0;

group_uniforms Panoramic_Mapping;
uniform sampler2D env_map : source_color,repeat_enable,filter_linear;


varying vec4 world_pos;


vec3 sample_environment(vec3 dir) {
    dir = normalize(dir);
    float lon = atan(dir.x, dir.z) + PI;
    lon /= (2.0 * PI);
    float lat = acos(clamp(dir.y, -1.0, 1.0));
    lat /= PI;
    vec2 uv = vec2(-lon,lat);
    return texture(env_map, uv).rgb;
}


void vertex() {
	world_pos = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
}

void fragment() {
	vec2 base_uv = UV;
	mat3 tbn = mat3(TANGENT,BINORMAL,NORMAL);

	vec3 normal_map = texture(texture_normal,UV).xyz * 2.0 - 1.0;
	vec3 normal = normalize(tbn * normal_map);

	vec4 albedo_tex = texture(texture_albedo, base_uv);

	// VIEW 和 NORMAL 均为视图空间（view space）
	NORMAL = normal;
    vec3 view_dir_vs = -VIEW;  // 片元到相机（需取负为入射）
    vec3 normal_vs = NORMAL;
    // 视图空间反射方向
    vec3 refl_vs = reflect(view_dir_vs, normal_vs);
    // 转换到世界空间（环境贴图通常用世界方向）
    vec3 refl_ws = normalize(mat3(INV_VIEW_MATRIX) * refl_vs);
	
	vec2 stretched_screen_uv = SCREEN_UV;
	
    // 拉伸写法不对?
	//float height_stretch = clamp(abs(world_pos.y - 0.0),0.,1.);
	//float screen_stretch = clamp(abs(SCREEN_UV.x *2.0 -1.0) - stretch_threshlod,0.,1.);
	//float angle_stretch = clamp(abs((CAMERA_DIRECTION_WORLD).y),0.,1.);
	
	//stretched_screen_uv.x *= (1.- height_stretch * screen_stretch * angle_stretch);
    vec4 reflect_col = texture(SSPR_Reflection, stretched_screen_uv);

	//reflect_amount = reflect_color.a * pow(1.0-dot(normal,VIEW),3.0);
	//EMISSION = reflect_col.rgb;
	vec3 cubemap = sample_environment(refl_ws).rgb;
	//ALBEDO = mix(albedo_tex.rgb ,reflect_col.rgb ,reflect_col.a);
	ALBEDO =  mix(cubemap.rgb * albedo_tex.rgb *2.0,reflect_col.rgb ,reflect_col.a);

	METALLIC = metallic;
	SPECULAR = specular;
	ROUGHNESS = roughness;
}
