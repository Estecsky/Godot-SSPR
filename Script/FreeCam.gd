@tool
extends Camera3D
class_name FreeCam3D

# 自由相机脚本

## 移动速度（单位：m/s）
@export_range(0.1, 80.0, 0.1) var move_speed := 5.0
## 冲刺速度
@export_range(0.1,100.0,0.1) var speed_add : float = 5.0
## 升降速度（单位：m/s）
@export_range(0.1, 50.0, 0.1) var lift_speed := 3.0
## 鼠标灵敏度（单位：度/像素）
@export_range(0.01, 1.0, 0.01) var mouse_sensitivity := 0.15
## 滚轮灵敏度
@export_range(0.1, 10.0) var zoom_sensitivity: float = 1.0
## 滚轮速度
@export_range(0.1, 10.0) var zoom_speed: float = 1.0
## 最小 FOV
@export_range(1.0, 179.0) var min_fov: float = 10.0
## 最大 FOV
@export_range(1.0, 179.0) var max_fov: float = 120.0
## 默认 FOV（缩小后回到的值）
@export_range(1.0, 179.0) var default_fov: float = 75.0
## 移动/旋转平滑系数（越大越平滑，0 表示不平滑）
@export_range(0.0, 1.0, 0.01) var smoothing := 0.15
## 最大俯仰角（度）
@export_range(0.0, 89.0, 1.0) var max_pitch := 85.0
## 是否隐藏并捕获鼠标
@export var capture_mouse := true

## 内部状态
var _target_velocity := Vector3.ZERO
var _current_velocity := Vector3.ZERO
var _mouse_delta := Vector2.ZERO
var _target_fov := fov
var _pitch := 0.0        # 当前俯仰角
var _yaw := 0.0          # 当前偏航角
var _is_debug : bool = false


func _ready() -> void:
	# 初始化方向
	_update_rotation_from_transform()
	if Engine.is_editor_hint():
		set_process(false)
		set_process_input(false)
		return

	if capture_mouse:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_mouse_delta = -event.relative * mouse_sensitivity

	if event.is_action_pressed("ui_cancel"):  # ESC 默认绑定为 ui_cancel
		get_tree().quit()

	if event is InputEventMouseButton:
		# 滚轮缩放
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_target_fov = clamp(_target_fov - (1.0 * zoom_sensitivity), min_fov, max_fov)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_target_fov = clamp(_target_fov + (1.0 * zoom_sensitivity), min_fov, max_fov)

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return

	if Input.is_action_just_pressed("swich_ctrl"):
		_is_debug = !_is_debug
	if _is_debug:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	else:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	# 1. 处理输入
	var input_dir := Vector3.ZERO
	input_dir.x = Input.get_axis("move_left", "move_right")   # A / D
	input_dir.z = Input.get_axis("move_forward", "move_back") # W / S
	input_dir.y = Input.get_axis("move_down", "move_up")      # Q / E
	
	if Input.is_action_pressed("sprint"):
		_target_velocity = (transform.basis * input_dir) * move_speed * speed_add
	else:
		_target_velocity = (transform.basis * input_dir) * move_speed
	_target_velocity.y = input_dir.y * lift_speed

	if !_is_debug:
	# 2. 平滑速度
		_current_velocity = _current_velocity.lerp(_target_velocity, 1.0 - exp(-delta * (1.0 / max(smoothing, 0.001))))

	# 3. 旋转
		_yaw   += _mouse_delta.x
		_pitch += _mouse_delta.y
		_pitch = clamp(_pitch, -max_pitch, max_pitch)
	else:
		_current_velocity = Vector3.ZERO

	rotation_degrees.y = _yaw
	rotation_degrees.x = _pitch
	_mouse_delta = Vector2.ZERO

	# 4. 位移
	global_translate(_current_velocity * delta)

	# 5.平滑FOV
	fov = lerp(fov, _target_fov, zoom_speed * delta)

# 从当前 transform 初始化 pitch/yaw，防止脚本启用时突然跳视角
func _update_rotation_from_transform() -> void:
	var euler = rotation_degrees
	_pitch = euler.x
	_yaw   = euler.y
