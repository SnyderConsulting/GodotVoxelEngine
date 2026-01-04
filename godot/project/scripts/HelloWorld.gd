extends Node3D

@export var camera_path: NodePath = NodePath("HelloCamera")
@export var cube_path: NodePath = NodePath("HelloCube")

@export var spin_speed := 0.6

var _camera: Camera3D
var _cube: MeshInstance3D

func _ready() -> void:
	_camera = get_node(camera_path) as Camera3D
	_cube = get_node(cube_path) as MeshInstance3D
	if _camera:
		_camera.current = true
		_camera.position = Vector3(0.0, 1.2, 6.0)
		_camera.look_at(Vector3.ZERO, Vector3.UP)

func _process(delta: float) -> void:
	if _cube:
		_cube.rotate_y(spin_speed * delta)
		_cube.rotate_x((spin_speed * 0.5) * delta)
