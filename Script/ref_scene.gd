extends Node3D
@onready var fps: Label = $FPS


func _process(delta: float) -> void:
	fps.text = str(Engine.get_frames_per_second()) + ' FPS'
