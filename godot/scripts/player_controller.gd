extends CharacterBody3D

@export var move_speed := 7.0
@export var jump_speed := 6.5
@export var gravity := 24.0
@export var mouse_sensitivity := 0.002

@onready var camera: Camera3D = $Camera3D

var _yaw := 0.0
var _pitch := 0.0

func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * mouse_sensitivity
		_pitch -= event.relative.y * mouse_sensitivity
		_pitch = clamp(_pitch, deg_to_rad(-89.0), deg_to_rad(89.0))
		rotation.y = _yaw
		camera.rotation.x = _pitch
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _physics_process(delta: float) -> void:
	var input_dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		input_dir.z -= 1.0
	if Input.is_key_pressed(KEY_S):
		input_dir.z += 1.0
	if Input.is_key_pressed(KEY_A):
		input_dir.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		input_dir.x += 1.0

	var basis := global_transform.basis
	var forward := -basis.z
	var right := basis.x
	var direction := (right * input_dir.x + forward * input_dir.z)
	if direction.length_squared() > 0.0:
		direction = direction.normalized()

	velocity.x = direction.x * move_speed
	velocity.z = direction.z * move_speed
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0
		if Input.is_key_pressed(KEY_SPACE):
			velocity.y = jump_speed

	move_and_slide()
