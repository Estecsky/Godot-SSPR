@tool
extends Node

# 相机射线方法重建世界空间位置的脚本
# 参考:https://zhuanlan.zhihu.com/p/648793922

@export var cam: Camera3D
@export var post_effect: MeshInstance3D

const NEAR_PLANE : float = 0.05   # 与项目设置保持一致
var top_left  := Vector4()
var x_extent  := Vector4()
var y_extent  := Vector4()

func _process(_dt) -> void:
	# 1. 拿到当前帧的投影矩阵
	var proj := cam.get_camera_projection()

	# 2. 把“平移”清零，得到 cview（相机在原点）
	var cv := Projection(Transform3D(cam.basis, Vector3())) # 旋转保留，位置归零
	var cview_proj := proj * cv

	# 3. 逆矩阵，把裁剪空间 [-1..1] 拉回世界空间
	var inv := cview_proj.inverse()

	# 4. 取近平面四个角（z = -1）
	top_left  = inv * Vector4(-1,  1, -1, 1)
	var top_right = inv * Vector4( 1,  1, -1, 1)
	var bottom_left = inv * Vector4(-1, -1, -1, 1)

	# 5. 算出两条跨度向量
	x_extent = top_right - top_left
	y_extent = bottom_left - top_left

	# 6. 丢给着色器
	var mat := post_effect.material_override as ShaderMaterial
	mat.set_shader_parameter("camera_pos", cam.global_transform.origin)
	mat.set_shader_parameter("top_left",  top_left)
	mat.set_shader_parameter("x_extent",  x_extent)
	mat.set_shader_parameter("y_extent",  y_extent)
	mat.set_shader_parameter("z_near_inv", 1.0 / NEAR_PLANE)
