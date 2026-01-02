extends Node3D

@export var vacuum_radius := 2.5
@export var vacuum_capture_radius := 0.8
@export var vacuum_max_dist := 40.0
@export var vacuum_rate := 24.0
@export var auto_autopilot := false
@export var autopilot_dump_interval := 2.0
@export var autopilot_toggle_gpu := false

@onready var world: Node = $World
@onready var player: CharacterBody3D = $Player
@onready var camera: Camera3D = $Player/Camera3D
@onready var vacuum_target: Node3D = $VacuumTarget
var _vacuum_accumulator := 0.0
var _debug_api: Node = null

func _ready() -> void:
	world.call("spawn_cube", Vector3i(-4, 0, -4), Vector3i(8, 8, 8))
	_debug_api = get_node_or_null("/root/DebugAPI")
	if _debug_api != null:
		_debug_api.call("attach", world, player, camera, vacuum_target)
		_debug_api.call("record_log", "[init] Godot prototype running")
	if auto_autopilot:
		world.call("set_use_gpu", true)
		if _debug_api != null:
			_debug_api.call("set_autopilot_output", "user://autopilot", autopilot_dump_interval)
			_debug_api.call("configure_autopilot", 1.0, autopilot_toggle_gpu, 0.8, vacuum_rate, vacuum_capture_radius)
			_debug_api.call("enable_autopilot", true)

func _process(delta: float) -> void:
	world.call("set_vacuum_target", vacuum_target.global_position, vacuum_capture_radius)
	world.call("step_sim", delta)
	_update_vacuum(delta)
	_update_debug()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F1:
			_toggle_gpu()

func _toggle_gpu() -> void:
	var current := bool(world.get("use_gpu"))
	world.call("set_use_gpu", not current)
	if _debug_api != null:
		_debug_api.call("record_log", "[sim] use_gpu=%s" % str(world.get("use_gpu")))

func _update_vacuum(delta: float) -> void:
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_vacuum_accumulator = 0.0
		return

	_vacuum_accumulator += vacuum_rate * delta
	var max_count := int(_vacuum_accumulator)
	if max_count > 0:
		_vacuum_accumulator -= max_count
		var ray_origin := camera.global_position
		var ray_dir := -camera.global_transform.basis.z.normalized()
		var tagged: int = int(world.call("vacuum_from_ray", ray_origin, ray_dir, vacuum_max_dist, vacuum_radius, max_count))
		if tagged > 0:
			if _debug_api != null:
				_debug_api.call("record_log", "[vacuum] tagged=%d" % tagged)

func _update_debug() -> void:
	if _debug_api == null:
		return
	var stats: Dictionary = world.call("get_debug_stats")
	_debug_api.call("set_stat", "camera", _vec3(camera.global_position))
	_debug_api.call("set_stat", "vacuum_target", _vec3(vacuum_target.global_position))
	_debug_api.call("set_stat", "static_voxels", stats["static_voxels"])
	_debug_api.call("set_stat", "vacuum_tagged", stats["vacuum_tagged"])
	_debug_api.call("set_stat", "vacuum_collected", stats["vacuum_collected"])
	_debug_api.call("set_stat", "vacuum_total", stats["vacuum_total"])
	_debug_api.call("set_stat", "use_gpu", stats["gpu"])
	_debug_api.call("set_stat", "sim_mode", stats["sim_mode"])
	_debug_api.call("set_stat", "sim_steps", stats["sim_steps"])
	_debug_api.call("set_stat", "sim_time_ms", stats["sim_time_ms"])

func _vec3(value: Vector3) -> String:
	return "(%.2f, %.2f, %.2f)" % [value.x, value.y, value.z]
