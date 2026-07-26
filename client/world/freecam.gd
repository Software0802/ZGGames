class_name FreeCam
extends Camera3D
## 调试用自由飞行相机。P2 阶段用它检验真实地形对不对得上；
## P4 接入第三人称控制后它退居 F4 调试用。

@export var speed := 60.0
@export var boost := 8.0
@export var mouse_sensitivity := 0.0022

var _yaw := 0.0
var _pitch := -0.25
var _captured := false


func _ready() -> void:
	# 远裁面要盖住 clipmap 的最外一级，否则远山会被裁掉半截
	far = maxf(far, Clipmap.view_radius() * 1.4)
	near = 0.5
	fov = 62.0
	_yaw = rotation.y
	_pitch = rotation.x


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_set_captured(true)
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_set_captured(false)
	elif event is InputEventMouseMotion and _captured:
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * mouse_sensitivity
		_pitch = clampf(_pitch - mm.relative.y * mouse_sensitivity, -1.5, 1.5)


func _set_captured(on: bool) -> void:
	_captured = on
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if on else Input.MOUSE_MODE_VISIBLE


func _process(delta: float) -> void:
	rotation = Vector3(_pitch, _yaw, 0.0)

	var dir := Vector3.ZERO
	if Input.is_action_pressed("move_forward"):
		dir -= basis.z
	if Input.is_action_pressed("move_back"):
		dir += basis.z
	if Input.is_action_pressed("move_left"):
		dir -= basis.x
	if Input.is_action_pressed("move_right"):
		dir += basis.x
	if Input.is_action_pressed("jump"):
		dir += Vector3.UP
	if Input.is_key_pressed(KEY_CTRL):
		dir -= Vector3.UP

	var v := speed * (boost if Input.is_action_pressed("run") else 1.0)
	if dir != Vector3.ZERO:
		position += dir.normalized() * v * delta
