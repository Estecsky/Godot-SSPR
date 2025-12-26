@tool
extends CompositorEffect
class_name ScreenSpacePlanarReflection

#region 导出变量
@export_group("SSPR")
#@export var planes : Array[Plane] = [Plane(Vector3(0,1,0), 0)] 
## 平面高度
@export var water_h : float = 0.0

#TAA相关
@export_group("TAA")
@export var TAA_enable :bool  = true
## TAA混合，越小越依赖历史帧，越大越依赖当前帧
@export var temporal_blend : float = 0.02
## 邻域搜索半径
@export var neighbor_clamp_radius : int = 1
## 序列长度
@export var sequence_length: int = 1     
## 抖动缩放
@export var jitter_scale: float = 0.5          
@export var halton_base_x: int = 2
@export var halton_base_y: int = 3

#endregion


func _init() -> void:
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	RenderingServer.call_on_render_thread(register_compute_shaders)
	access_resolved_color = true
	access_resolved_depth = true

func _notification(what:int) -> void:
	if what == NOTIFICATION_PREDELETE:
		# When this is called it should be safe to clean up our shader.
		# If not we'll crash anyway because we can no longer call our _render_callback.
		if sspr_scatter_shader.is_valid():
			rd.free_rid(sspr_scatter_shader)
		if sspr_resolve_shader.is_valid():
			rd.free_rid(sspr_resolve_shader)
		if sspr_temporal_shader.is_valid():
			rd.free_rid(sspr_temporal_shader)
		if sspr_blur_shader.is_valid():
			rd.free_rid(sspr_blur_shader)
		if sspr_blur_down_shader.is_valid():
			rd.free_rid(sspr_blur_down_shader)
		if sspr_blur_up_shader.is_valid():
			rd.free_rid(sspr_blur_up_shader)
		if tex_current_hash.is_valid():
			rd.free_rid(tex_current_hash)
		if tex_current_resolve.is_valid():
			rd.free_rid(tex_current_resolve)
		if tex_history.is_valid():
			rd.free_rid(tex_history)
		if tex_blurred_rt1.is_valid():
			rd.free_rid(tex_blurred_rt1)
		if tex_blurred_rt2.is_valid():
			rd.free_rid(tex_blurred_rt2)
		if view_proj_mat_buffer.is_valid():
			rd.free_rid(view_proj_mat_buffer)
		if tex_copy_shader.is_valid():
			rd.free_rid(tex_copy_shader)
		if tex_copy_pipeline.is_valid():
			rd.free_rid(tex_copy_pipeline)

			
#region 内置变量
###############################################################################
# Everything after this point is designed to run on our rendering thread

var rd : RenderingDevice

var nearest_sampler : RID
var linear_sampler : RID

var frame_index : int = 0

var sspr_scatter_shader : RID
var sspr_scatter_pipeline : RID

var sspr_resolve_shader : RID
var sspr_resolve_pipeline : RID

var sspr_temporal_shader :RID
var sspr_temporal_pipeline : RID

var sspr_blur_shader : RID
var sspr_blur_pipeline : RID

var sspr_blur_down_shader : RID
var sspr_blur_down_pipeline : RID

var sspr_blur_up_shader : RID
var sspr_blur_up_pipeline : RID

var tex_copy_shader : RID
var tex_copy_pipeline : RID

## 本帧编码hash 格式为r32uint
var tex_current_hash : RID   
## 本帧解码hash后，完成采样后未模糊的反射颜色图
var tex_current_resolve : RID
## 上帧历史 
var tex_history : RID   
## TAA结果
var tex_temporal : RID
## 模糊后最终图像
var tex_blurred_rt1 : RID
var tex_blurred_rt2 : RID  

var tex_current_display : RID

var view_proj_mat_buffer : RID

var tex_size : Vector2i
var downscaled_size: Vector2i
var texture2drd : Texture2DRD

var mat_ssbo : PackedFloat32Array
var viewproj_mat_array : Array
var prev_jitter_view_proj_mat : Projection
var prev_view_proj : Projection

var Dual_Kawase_down_blur : String = "res://SSPR_demo/Compute Shader/sspr_blur_downscaling.glsl"
var Dual_Kawase_up_blur : String = "res://SSPR_demo/Compute Shader/sspr_blur_upscaling.glsl"
var Gaussian_blur : String = "res://SSPR_demo/Compute Shader/gaussian_blur.glsl"

var blur_shader_up_path : String
var blur_shader_down_path : String

#endregion

#region  动态显示导出参数的编辑器面板
#---- 动态显示的变量
var blur_enable : bool = true:
	set(value):
		blur_enable = value
		notify_property_list_changed()  # 刷新属性列表

var blur_mode : int = 1:
	set(value):
		blur_mode = value
		notify_property_list_changed()  # 刷新属性列表
var blur_iteration : int = 2:
	set(value):
		if blur_iteration != value:
			force_rebuild_pyramid()
		blur_iteration = value
var blur_downscaling : int = 2
var blur_radius : float = 0.5;
var blur_strength : float = 1.0;

func _get_property_list() -> Array:
	var properties = []
	# 添加分组标题
	properties.append({
		"name": "Blur",
		"type": TYPE_NIL,
		"usage": PROPERTY_USAGE_GROUP,  # 分组标志
		#"hint_string": "dynamic_"
	})
	properties.append({
		"name": "blur_enable",
		"type": TYPE_BOOL,
		"usage": PROPERTY_USAGE_DEFAULT
	})
	if blur_enable:
		properties.append({
			"name": "blur_mode",
			"type": TYPE_INT,
			"hint" : PROPERTY_HINT_ENUM ,
			"hint_string": "Dual_Kawase:0, Gaussian:1",
			"usage": PROPERTY_USAGE_DEFAULT
		})
		properties.append({
			"name" : "blur_radius",
			"type" : TYPE_FLOAT,
			"hint" : PROPERTY_HINT_RANGE,
			"hint_string" : "0.0,6.0,0.1",
			"usage" : PROPERTY_USAGE_DEFAULT
		})
		if blur_mode == 0:
			properties.append({
				"name" : "blur_iteration",
				"type" : TYPE_INT,
				"hint" : PROPERTY_HINT_RANGE,
				"hint_string" : "2,10,1",
				"usage" : PROPERTY_USAGE_DEFAULT
			})
			properties.append({
				"name" : "blur_downscaling",
				"type" : TYPE_INT,
				"hint" : PROPERTY_HINT_RANGE,
				"hint_string" : "1,8,1",
				"usage" : PROPERTY_USAGE_DEFAULT
			})
		elif blur_mode == 1:
			properties.append({
				"name" : "blur_strength",
				"type" : TYPE_FLOAT,
				"hint" : PROPERTY_HINT_RANGE,
				"hint_string" : "0.0,1.0,0.01",
				"usage" : PROPERTY_USAGE_DEFAULT
			})
			
	return properties
	
# 处理动态属性的读写（必须实现）
func _set(property: StringName, value) -> bool:
	match property:
		"blur_enable":
			blur_enable = value
			return true
		"blur_mode":
			blur_mode = value
			return true
		"blur_iteration":
			blur_iteration = value
			return true
		"blur_radius":
			blur_radius = value
			return true
		"blur_downscaling":
			blur_downscaling = value
			return true
		"blur_strength":
			blur_strength = value
			return true
	return false
	
# 获取属性值
func _get(property: StringName):
	match property:
		"blur_enable":
			return blur_enable
		"blur_mode":
			return blur_mode
		"blur_iteration":
			return blur_iteration
		"blur_radius":
			return blur_radius
		"blur_downscaling":
			return blur_downscaling
		"blur_strength":
			return blur_strength
	return null

# 设置属性是否可以回滚
func _property_can_revert(property: StringName) -> bool:
	match property:
		"blur_enable":
			return true
		"blur_iteration":
			return true
		"blur_radius":
			return true
		"blur_downscaling":
			return true
		"blur_strength":
			return true
	return false
# 设置属性的回滚值
func _property_get_revert(property: StringName):
	match property:
		"blur_enable":
			return true
		"blur_iteration":
			return 2
		"blur_radius":
			return 1.5
		"blur_downscaling":
			return 2
		"blur_strength":
			return 1.0
	return null

#endregion

#region 功能函数
func _create_hash_rdtexture():
	var tf = RDTextureFormat.new()
	tf.format = RenderingDevice.DATA_FORMAT_R32_UINT
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tf.width = tex_size.x
	tf.height = tex_size.y
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |\
	RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |\
	RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT |\
	RenderingDevice.TEXTURE_USAGE_STORAGE_ATOMIC_BIT
	
	var tv = RDTextureView.new()
	
	tex_current_hash = rd.texture_create(tf, tv,[])
	
func _create_color_buffer_rd():
	var tf = RDTextureFormat.new()
	tf.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tf.width = tex_size.x
	tf.height = tex_size.y
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |\
	 RenderingDevice.TEXTURE_USAGE_STORAGE_BIT 
	 #RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |\
	 #RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	
	var tv = RDTextureView.new()
	
	tex_current_resolve = rd.texture_create(tf,tv,[])
	tex_history = rd.texture_create(tf, tv,[])
	tex_temporal = rd.texture_create(tf,tv,[])
	


## 创建存储缓冲区函数
func create_ssbo_uniform(buffer: RID, binding) -> RDUniform:
	# Create a uniform to assign the buffer to the rendering device
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = binding # this needs to match the "binding" in our shader file
	uniform.add_id(buffer)
	return uniform

func get_image_uniform(image : RID, binding : int = 0) -> RDUniform:
	var uniform : RDUniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = binding
	uniform.add_id(image)

	return uniform

func get_sampler_uniform(image : RID, binding : int = 0, linear : bool = true) -> RDUniform:
	var uniform : RDUniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = binding
	if linear:
		uniform.add_id(linear_sampler)
	else:
		uniform.add_id(nearest_sampler)
	uniform.add_id(image)

	return uniform

func get_view_proj_mat(proj : Projection,view_mat : Transform3D) -> Array:
	var cam_proj : Projection = proj
	var cam_view : Projection = Projection(Transform3D(view_mat.basis, view_mat.origin))
	var view_proj_mat = cam_proj * cam_view
	var inv_view_proj_mat = view_proj_mat.inverse()
	return [view_proj_mat,inv_view_proj_mat]

## Halton 序列生成 ==================
func radical_inverse(base: int, i: int) -> float:
	var result: float = 0.0
	var f: float = 1.0 / float(base)
	
	while i > 0:
		result += f * float(i % base)
		f /= float(base)
		i /= base
	
	return result

func get_halton_jitter(frame_index_in: int) -> Vector2:
	var i = frame_index_in % sequence_length
	var x = radical_inverse(halton_base_x, i) - 0.5
	var y = radical_inverse(halton_base_y, i) - 0.5
	
	var jitter = Vector2(x, y) *2.0
	return jitter * jitter_scale
	
func apply_jitter_to_proj(original_proj: Projection, jitter_pixels: Vector2) -> Array:
	
	var jitter_clip = Vector2(
		jitter_pixels.x  / tex_size.x, 
		jitter_pixels.y  / tex_size.y 
	)
	
	var jittered_proj = original_proj
	jittered_proj[2][0] += jitter_clip.x  # tx
	jittered_proj[2][1] += jitter_clip.y  # ty
	
	return [jittered_proj,jitter_clip]


## Pipeline Validation
func validate_pipelines():
	return sspr_scatter_pipeline.is_valid() && sspr_resolve_pipeline.is_valid() && sspr_temporal_pipeline.is_valid()
#endregion


#region register_compute_shaders
## 注册并初始化计算着色器
func register_compute_shaders():
	# Create a local rendering device.
	rd = RenderingServer.get_rendering_device()
	if not rd:
		push_warning("设备不支持 Compute Shader，SSPR禁用")
		return
	# Get the window size
	tex_size = DisplayServer.window_get_size()

	# Create our samplers
	var sampler_state : RDSamplerState = RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	nearest_sampler = rd.sampler_create(sampler_state)

	sampler_state = RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	linear_sampler = rd.sampler_create(sampler_state)

	# Load GLSL shader
	# sspr_scatter
	var shader_file := load("res://SSPR_demo/Compute Shader/sspr_scatter.glsl")
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	sspr_scatter_shader = rd.shader_create_from_spirv(shader_spirv)
	sspr_scatter_pipeline = rd.compute_pipeline_create(sspr_scatter_shader)
	
	# sspr_resolve
	shader_file  = load("res://SSPR_demo/Compute Shader/sspr_resolve.glsl")
	shader_spirv = shader_file.get_spirv()
	sspr_resolve_shader = rd.shader_create_from_spirv(shader_spirv)
	sspr_resolve_pipeline = rd.compute_pipeline_create(sspr_resolve_shader)
	
	# sspr_temporal
	shader_file  = load("res://SSPR_demo/Compute Shader/sspr_temporal.glsl")
	shader_spirv = shader_file.get_spirv()
	sspr_temporal_shader = rd.shader_create_from_spirv(shader_spirv)
	sspr_temporal_pipeline = rd.compute_pipeline_create(sspr_temporal_shader)
	
	# sspr_blur_down
	shader_file  = load(Dual_Kawase_down_blur)
	shader_spirv = shader_file.get_spirv()
	sspr_blur_down_shader = rd.shader_create_from_spirv(shader_spirv)
	sspr_blur_down_pipeline = rd.compute_pipeline_create(sspr_blur_down_shader)
	
	# sspr_blur_up
	shader_file  = load(Dual_Kawase_up_blur)
	shader_spirv = shader_file.get_spirv()
	sspr_blur_up_shader = rd.shader_create_from_spirv(shader_spirv)
	sspr_blur_up_pipeline = rd.compute_pipeline_create(sspr_blur_up_shader)

	# sspr_blur
	shader_file  = load(Gaussian_blur)
	shader_spirv = shader_file.get_spirv()
	sspr_blur_shader = rd.shader_create_from_spirv(shader_spirv)
	sspr_blur_pipeline = rd.compute_pipeline_create(sspr_blur_shader)
	
	# 使用计算着色器纹理复制
	shader_file  = load("res://SSPR_demo/Compute Shader/texture_copy.glsl")
	shader_spirv = shader_file.get_spirv()
	tex_copy_shader = rd.shader_create_from_spirv(shader_spirv)
	tex_copy_pipeline = rd.compute_pipeline_create(sspr_blur_shader)
	
	_create_hash_rdtexture()
	_create_color_buffer_rd()

	tex_blurred_rt1 = _create_rt(tex_size)
	tex_blurred_rt2 = _create_rt(tex_size)

	# 初始化矩阵缓冲区
	var mat_bytes_create : PackedByteArray = PackedByteArray()
	mat_bytes_create.resize(192)
	mat_bytes_create.fill(0)
	view_proj_mat_buffer = rd.storage_buffer_create(mat_bytes_create.size(),mat_bytes_create)
	
	# Dual_Kawase需要初始化金字塔数组
	init_pyramid()
	
	# 初始化最终反射图像指向的目标图像
	texture2drd = Texture2DRD.new()
	texture2drd.texture_rd_rid = tex_current_resolve
	# 全局参数供shader使用
	RenderingServer.global_shader_parameter_set("SSPR_Reflection", texture2drd)
	
#endregion

##核心函数：自定义渲染pass
func _render_callback(p_effect_callback_type: int, p_render_data: RenderData) -> void:
	if rd and p_effect_callback_type == CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT and validate_pipelines():
		# Get our render scene buffers object, this gives us access to our render buffers. 
		# Note that implementation differs per renderer hence the need for the cast.
		var render_scene_buffers : RenderSceneBuffersRD = p_render_data.get_render_scene_buffers()
		var render_scene_data : RenderSceneDataRD = p_render_data.get_render_scene_data()
		if render_scene_buffers and render_scene_data:
			# 清理
			viewproj_mat_array.clear()
			mat_ssbo.clear()
			rd.texture_clear(tex_current_hash, Color(0.0, 0.0, 0.0, 0.0), 0, 1, 0, 1)
			
			# 获取当前帧颜色，深度缓冲
			#var color_image = render_scene_buffers.get_color_texture()
			var color_image = render_scene_buffers.get_texture("render_buffers","color")
			#var depth_image = render_scene_buffers.get_depth_texture()
			var depth_image = render_scene_buffers.get_texture("render_buffers","depth")
			# 矩阵获取
			var projection : Projection = render_scene_data.get_cam_projection() # 投影矩阵
			
			var jitter_pixels = get_halton_jitter(frame_index)
			var jitter_array : Array = apply_jitter_to_proj(projection,jitter_pixels)
			var jittered_proj : Projection = jitter_array[0]
			var view_matrix : Transform3D = render_scene_data.get_cam_transform().inverse()
			viewproj_mat_array = get_view_proj_mat(jittered_proj,view_matrix) 
			# 如果是第一帧，prev_view_proj 可能为空，初始化它
			if prev_view_proj == Projection():
				prev_view_proj = projection * Projection(Transform3D(view_matrix.basis,view_matrix.origin))
			viewproj_mat_array.append(prev_view_proj)
			
			set_and_update_mat_buffer(viewproj_mat_array,view_proj_mat_buffer)
			#########################开始绘制Pass############################
			# 1.传入深度，Hash Buffer ，做深度重建，翻转，编码Hash id
			_run_scatter_pass(depth_image)
			# 2.传入Hash map ,颜色缓冲，前一帧颜色，做解码Hash , 采样写入反射颜色，填补空洞
			_run_resolve_pass(color_image)
			# 3.TAA进一步补洞
			_run_temporal_pass(depth_image , jitter_array[1])
			
			if TAA_enable:
				tex_current_display = tex_temporal
			else:
				tex_current_display = tex_current_resolve
				
			# 4.模糊
			if blur_enable:
				if texture2drd.texture_rd_rid != tex_blurred_rt2: 
					texture2drd.texture_rd_rid = tex_blurred_rt2
					
				if blur_mode == 0:
					copy_src_to_rt1(tex_current_display)
					_run_dual_kawase_blur_pass(tex_current_display,tex_blurred_rt2)
				elif blur_mode == 1:
					copy_src_to_rt1(tex_current_display)
					
					_run_gaussian_blur_pass(0)
					
					_run_gaussian_blur_pass(1)
			else:
				if texture2drd.texture_rd_rid != tex_current_display:
					texture2drd.texture_rd_rid = tex_current_display
					
			# 帧末尾：更新上一帧矩阵为当前帧
			prev_view_proj = projection * Projection(Transform3D(view_matrix.basis,view_matrix.origin))
			# 复制存储前一帧
			frame_index += 1
			if blur_enable:
				#texture_copy()方法只在pc有效？移动端实机无法生效
				#rd.texture_copy(tex_blurred_rt2,tex_history,Vector3.ZERO,Vector3.ZERO,Vector3(tex_size.x,tex_size.y,0.0),0,0,0,0)
				#_copy_texture_via_compute(tex_blurred_rt2,tex_history,tex_size)
				tex_history = tex_blurred_rt2
			else:
				#rd.texture_copy(tex_temporal,tex_history,Vector3.ZERO,Vector3.ZERO,Vector3(tex_size.x,tex_size.y,0.0),0,0,0,0)
				#_copy_texture_via_compute(tex_temporal,tex_history,tex_size)
				tex_history = tex_temporal
				
func set_and_update_mat_buffer(mat_array : Array, current_mat_buffer:RID):
	# view-proj_mat - jitter
	for i in range(4):
		for j in range(4):
			mat_ssbo.push_back(mat_array[0][i][j])
	# inv view-proj_mat -jitter
	for i in range(4):
		for j in range(4):
			mat_ssbo.push_back(mat_array[1][i][j])
	## prev_view-proj 
	for i in range(4):
		for j in range(4):
			mat_ssbo.push_back(mat_array[2][i][j])
			
	var mat_bytes = mat_ssbo.to_byte_array()
	
	rd.buffer_update(current_mat_buffer,0,mat_bytes.size(),mat_bytes)
	
				
####################### Compute Passes ########################
#region UAV编码与解码
## 	传入矩阵，深度，Hash Buffer ，做深度重建，翻转，编码Hash id
func _run_scatter_pass(depth_texture : RID):
	
	var push_constant = PackedFloat32Array()

	push_constant.push_back(water_h)
	for i in range(3):
		push_constant.push_back(0.0)

	var push_const_bytes : PackedByteArray = push_constant.to_byte_array()

	var uniforms = [
		get_sampler_uniform(depth_texture,0),
		get_image_uniform(tex_current_hash,1),
		create_ssbo_uniform(view_proj_mat_buffer,2)
	]
	var uniform_set = UniformSetCacheRD.get_cache(sspr_scatter_shader, 0, uniforms)

	var cl = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, sspr_scatter_pipeline)
	rd.compute_list_set_push_constant(cl, push_const_bytes, push_const_bytes.size())
	rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	rd.compute_list_dispatch(cl, ceili((tex_size.x)/16.0), ceili((tex_size.y)/16.0), 1)
	rd.compute_list_end()

## 传入Hash map ,颜色缓冲，前一帧颜色，做解码Hash , 采样写入反射颜色，填补空洞
func _run_resolve_pass(color_texture : RID):

	var uniforms = [
		get_sampler_uniform(color_texture , 0),
		get_image_uniform(tex_current_hash,1),
		get_image_uniform(tex_current_resolve,2),
	]
	var uniform_set = UniformSetCacheRD.get_cache(sspr_resolve_shader,0,uniforms)
	
	var cl = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, sspr_resolve_pipeline)
	rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	rd.compute_list_dispatch(cl, ceili((tex_size.x)/16.0), ceili((tex_size.y)/16.0), 1)
	rd.compute_list_end()
	
#endregion

#region TAA
## 时域累积混合
func _run_temporal_pass(depth_texture : RID,jitter_offset : Vector2):
	var push_constant = PackedFloat32Array()
	
	push_constant.append_array([
		temporal_blend,
		neighbor_clamp_radius,
		jitter_offset.x,
		jitter_offset.y,
	])
	var push_const_bytes : PackedByteArray = push_constant.to_byte_array()

	var uniforms = [
		get_sampler_uniform(tex_current_resolve, 0),
		get_sampler_uniform(tex_history, 1),
		get_sampler_uniform(depth_texture,2),
		create_ssbo_uniform(view_proj_mat_buffer,3),
		get_image_uniform(tex_temporal,4),
	]
	var uniform_set = UniformSetCacheRD.get_cache(sspr_temporal_shader, 0, uniforms)

	var cl = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, sspr_temporal_pipeline)
	rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	rd.compute_list_set_push_constant(cl, push_const_bytes, push_const_bytes.size())
	rd.compute_list_dispatch(cl, ceili((tex_size.x)/16.0), ceili((tex_size.y)/16.0), 1)
	rd.compute_list_end()
	
	
#endregion

#region 高斯模糊 pass

func copy_src_to_rt1(tex: RID):
	#tex_blurred_rt1  = tex_temporal
	_copy_texture_via_compute(tex,tex_blurred_rt1,tex_size)
	#rd.texture_copy(tex_temporal,tex_blurred_rt1,Vector3.ZERO,Vector3.ZERO,Vector3(tex_size.x,tex_size.y,0.0),0,0,0,0)

func _run_gaussian_blur_pass(blur_pass: int):

	var uniforms = [
		get_sampler_uniform(tex_blurred_rt1 , 0),
		get_image_uniform(tex_blurred_rt2 , 1)
	]
	var uniform_set = UniformSetCacheRD.get_cache(sspr_blur_shader, 0, uniforms)

	var push_const = PackedFloat32Array()

	push_const.append_array([
		blur_pass,
		blur_radius,
		blur_strength,
		0.0,
	])

	var cl = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, sspr_blur_pipeline)
	rd.compute_list_set_push_constant(cl,push_const.to_byte_array(),push_const.size() * 4)
	rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	rd.compute_list_dispatch(cl, ceili((tex_size.x)/16.0), ceili((tex_size.y)/16.0), 1)
	rd.compute_list_end()

	# ping-pong
	#tex_blurred_rt1  = tex_blurred_rt2
	# 这里使用启动Compute Shader 实现纹理复制
	_copy_texture_via_compute(tex_blurred_rt2,tex_blurred_rt1,tex_size)
	# texture_copy()方法只在pc有效？移动端实机无法生效
	#rd.texture_copy(tex_blurred_rt2,tex_blurred_rt1,Vector3.ZERO,Vector3.ZERO,Vector3(tex_size.x,tex_size.y,0.0),0,0,0,0)

#endregion

#region 手动纹理复制

# 通用纹理拷贝函数（移动端兼容）
func _copy_texture_via_compute(src_rid: RID, dst_rid: RID, dst_size: Vector2i):
	if not src_rid.is_valid() or not dst_rid.is_valid() :
		return
	
	var uniforms = [
		get_sampler_uniform(src_rid, 0),  # 输入
		get_image_uniform(dst_rid, 1)     # 输出图像
	]
	var uniform_set = UniformSetCacheRD.get_cache(
		tex_copy_shader, 
		0, 
		uniforms
	)
	
	## Push常量
	var push_const = PackedFloat32Array()
	push_const.append_array([
		float(dst_size.x),
		float(dst_size.y),
		0.0,
		0.0
	])
	
	# 调度Compute Shader
	var cl = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl,tex_copy_pipeline)
	rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	rd.compute_list_set_push_constant(cl, push_const.to_byte_array(), push_const.size() * 4)
	var group_x = ceil(dst_size.x / 16.0)
	var group_y = ceil(dst_size.y / 16.0)
	rd.compute_list_dispatch(cl, group_x, group_y, 1)
	rd.compute_list_end()

#endregion

#region Dual_Kawase blur pass

const k_MaxPyramidSize : int= 16;
# 记录当前生效的迭代次数（用于检测是否变更）
var _current_iteration: int = -1
# 记录当前生效的纹理尺寸（用于检测视口/源纹理尺寸变更）
var _current_tex_size: Vector2i = Vector2i(-1, -1)
# 标记金字塔是否已初始化完成
var _pyramid_inited: bool = false
# 定义金字塔层级结构（对应Unity的Level结构体）
class Level:
	var down_rid: RID = RID()  # 下采样RT的RID
	var up_rid: RID = RID()    # 上采样RT的RID
	var size: Vector2i = Vector2i(0, 0)  # 该层级RT的尺寸
	
# 金字塔数组（存储所有层级的RT信息）
var pyramid: Array[Level] = []
# 创建降/升采样的纹理

func init_pyramid():
	# 初始化金字塔数组
	pyramid = []
	for i in range(k_MaxPyramidSize):
		var level : Level = Level.new()
		pyramid.append(level)

func force_rebuild_pyramid():
	_current_iteration = -1  # 重置缓存状态，触发重建
	_pyramid_inited = false

func _create_rt(rt_size: Vector2i) -> RID:
	if rt_size.x <= 0 or rt_size.y <= 0:
		return RID()
	
	var tf = RDTextureFormat.new()
	tf.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tf.width = rt_size.x
	tf.height = rt_size.y
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |\
	 				RenderingDevice.TEXTURE_USAGE_STORAGE_BIT 
	 				#RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |\
	 				#RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	
	var tv = RDTextureView.new()
	return rd.texture_create(tf, tv, [])

# 释放单个RT
func _free_rt(rid: RID):
	if rid.is_valid():
		rd.free_rid(rid)

# 释放金字塔所有RT资源
func _free_pyramid_resources():
	for level in pyramid:
		_free_rt(level.down_rid)
		_free_rt(level.up_rid)
		# 重置层级状态
		level.down_rid = RID()
		level.up_rid = RID()
		level.size = Vector2i(0, 0)
	_pyramid_inited = false
	
func _run_dual_kawase_blur_pass(source_rid: RID, _dest_rid: RID):
	if not source_rid.is_valid():
		return
	
	# 2. 预创建金字塔各层级RT（基于迭代次数）
	_lazy_init_pyramid()
	
	# 3. 下采样（构建模糊金字塔）
	_run_downscaling_pass(source_rid)
	
	# 4. 上采样（还原尺寸并模糊）
	_run_upscaling_pass()
	
	# 5. 将最终模糊结果拷贝到目标RT
	# texture_copy()方法只在pc有效？移动端实机无法生效
	#rd.texture_copy(pyramid[0].up_rid,_dest_rid,Vector3.ZERO,Vector3.ZERO,Vector3(tex_size.x,tex_size.y,0.0),0,0,0,0)
	# 手动启用计算着色器完成复制
	_copy_texture_via_compute(pyramid[0].up_rid,_dest_rid,tex_size)
	
# 初始化金字塔各层级的RT尺寸和资源
func _lazy_init_pyramid():
	# 检测是否需要重建：迭代次数变更 或 纹理尺寸变更 或 未初始化
	var need_rebuild = false
	if blur_iteration != _current_iteration or tex_size != _current_tex_size or not _pyramid_inited:
		need_rebuild = true

	# 无需重建则直接返回
	if not need_rebuild:
		return

	# 1. 释放旧的金字塔资源（如果有）
	_free_pyramid_resources()

	# 2. 更新缓存状态
	_current_iteration = blur_iteration
	_current_tex_size = tex_size
	_pyramid_inited = true

	# 3. 重新创建金字塔各层级RT
	var current_size = tex_size
	
	for i in range(blur_iteration):
		# 存储当前层级的尺寸
		pyramid[i].size = current_size
		# 创建下采样/上采样RT（复用核心：创建后保留，直到参数变更）
		pyramid[i].down_rid = _create_rt(current_size)
		pyramid[i].up_rid = _create_rt(current_size)
		# 下一层级尺寸减半（最小为1x1）
		current_size = Vector2i(
			max(int(current_size.x / blur_downscaling), 1),
			max(int(current_size.y / blur_downscaling), 1)
		)

# 下采样：逐层级缩小+模糊（对应Unity的Downsample阶段）
func _run_downscaling_pass(source_rid: RID):
	# 初始输入为源纹理
	var last_down_rid = source_rid
	
	for i in range(blur_iteration):
		var current_level = pyramid[i]
		# 跳过无效RT
		if not current_level.down_rid.is_valid():
			continue
		
		# 构建UniformSet（输入纹理->采样器，输出纹理->存储图像）
		var uniforms = [
			get_sampler_uniform(last_down_rid, 0),  # 输入采样器
			get_image_uniform(current_level.down_rid, 1)  # 输出存储图像
		]
		var uniform_set = UniformSetCacheRD.get_cache(
			sspr_blur_down_shader, 0, uniforms
		)
		
		# Push常量：传递当前层级的尺寸、模糊半径等
		var push_const = PackedFloat32Array()
		push_const.append_array([
			float(current_level.size.x),   # 当前层级宽度
			float(current_level.size.y),   # 当前层级高度
			blur_radius,                   # 模糊半径
			0.0,          
		])
		
		# 调度计算着色器
		var cl = rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(cl, sspr_blur_down_pipeline)
		rd.compute_list_set_push_constant(cl, push_const.to_byte_array(), push_const.size() * 4)
		rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
		# 线程组调度：按16x16分组
		var group_x = ceil(current_level.size.x / 16.0)
		var group_y = ceil(current_level.size.y / 16.0)
		rd.compute_list_dispatch(cl, group_x, group_y, 1)
		rd.compute_list_end()
		
		# 更新下采样链的最后一个RT
		last_down_rid = current_level.down_rid

# 上采样：反向迭代，逐层级放大+模糊（对应Unity的Upsample阶段）
func _run_upscaling_pass():
	# 初始输入为最后一层下采样的RT
	var last_up_rid = pyramid[blur_iteration - 1].down_rid
	
	# 处理迭代次数=1的情况
	if blur_iteration <= 1:
		# 直接将下采样结果赋值给up_rid，避免空循环
		pyramid[0].up_rid = last_up_rid
		return
		
	# 反向迭代（从倒数第二层往第一层）
	for i in range(blur_iteration - 2, -1, -1):
		var current_level = pyramid[i]
		if not current_level.up_rid.is_valid():
			continue
		
		# 构建UniformSet
		var uniforms = [
			get_sampler_uniform(last_up_rid, 0),
			get_image_uniform(current_level.up_rid, 1)
		]
		var uniform_set = UniformSetCacheRD.get_cache(
			sspr_blur_up_shader, 0, uniforms
		)
		
		# Push常量
		var push_const = PackedFloat32Array()
		push_const.append_array([
			float(current_level.size.x),
			float(current_level.size.y),
			blur_radius,
			0.0,
		])
		
		# 调度计算着色器
		var cl = rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(cl, sspr_blur_up_pipeline)
		rd.compute_list_set_push_constant(cl, push_const.to_byte_array(), push_const.size() * 4)
		rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
		var group_x = ceil(current_level.size.x / 16.0)
		var group_y = ceil(current_level.size.y / 16.0)
		rd.compute_list_dispatch(cl, group_x, group_y, 1)
		rd.compute_list_end()
		
		# 更新上采样链的最后一个RT
		last_up_rid = current_level.up_rid

#endregion
