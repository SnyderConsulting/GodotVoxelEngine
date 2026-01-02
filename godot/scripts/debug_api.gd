extends Node
class_name DebugAPI

var max_logs := 40
var logs: Array[String] = []
var stats := {}
var refs := {}
var _autopilot_enabled := false
var _autopilot_interval := 1.0
var _autopilot_timer := 0.0
var _autopilot_toggle_gpu := true
var _autopilot_yaw := 0.0
var _autopilot_pitch := -0.2
var _autopilot_sweep_speed := 0.8
var _autopilot_vacuum_rate := 24.0
var _autopilot_vacuum_radius := 2.5
var _autopilot_vacuum_max_dist := 40.0
var _autopilot_vacuum_capture := 0.8
var _autopilot_vacuum_accum := 0.0
var _autopilot_dump_interval := 2.0
var _autopilot_dump_timer := 0.0
var _autopilot_output_dir := "user://autopilot"
var _autopilot_frame_id := 0
var _heartbeat_interval := 5.0
var _heartbeat_timer := 0.0
var _prevent_quit := true
var _last_world_stats := {}
var _last_world_stats_prev := {}

func _ready() -> void:
	set_process(true)
	get_tree().set_auto_accept_quit(false)
	_ensure_output_dir()

func _notification(what: int) -> void:
	if not _prevent_quit:
		return
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_WM_GO_BACK_REQUEST:
		get_tree().set_auto_accept_quit(false)
		record_log("[auto] quit_request_ignored")

func _process(delta: float) -> void:
	_heartbeat_timer += delta
	if _heartbeat_timer >= _heartbeat_interval:
		_heartbeat_timer = 0.0
		_log_heartbeat()
	if not _autopilot_enabled:
		return
	var world := refs.get("world", null) as Node
	var camera := refs.get("camera", null) as Node3D
	var vacuum_target := refs.get("vacuum_target", null) as Node3D
	if world == null or camera == null:
		return
	_autopilot_timer += delta
	_autopilot_dump_timer += delta
	_autopilot_yaw += _autopilot_sweep_speed * delta
	var yaw_basis := Basis(Vector3.UP, _autopilot_yaw)
	var pitch_basis := Basis(Vector3.RIGHT, _autopilot_pitch)
	var dir: Vector3 = ((yaw_basis * pitch_basis) * (-Vector3.FORWARD)).normalized()
	var ray_origin := camera.global_position
	_autopilot_vacuum_accum += _autopilot_vacuum_rate * delta
	var max_count: int = int(_autopilot_vacuum_accum)
	if max_count > 0:
		_autopilot_vacuum_accum -= max_count
		var moved: int = int(world.call("vacuum_from_ray", ray_origin, dir, _autopilot_vacuum_max_dist, _autopilot_vacuum_radius, max_count))
		if moved > 0:
			record_log("[auto] moved=%d" % moved)
	var target := vacuum_target if vacuum_target != null else camera
	world.call("set_vacuum_target", target.global_position, _autopilot_vacuum_capture)

	if _autopilot_toggle_gpu and _autopilot_timer >= _autopilot_interval:
		_autopilot_timer = 0.0
		if world.has_method("set_use_gpu"):
			var current := bool(world.get("use_gpu"))
			world.call("set_use_gpu", not current)
			record_log("[auto] use_gpu=%s" % str(world.get("use_gpu")))

	if _autopilot_dump_timer >= _autopilot_dump_interval:
		_autopilot_dump_timer = 0.0
		_autopilot_frame_id += 1
		_dump_state(_autopilot_frame_id)
		_capture_frame(_autopilot_frame_id)


func _log_heartbeat() -> void:
	var world := refs.get("world", null) as Node
	if world == null:
		record_log("[auto] heartbeat (no world)")
		return
	_last_world_stats_prev = _last_world_stats
	_last_world_stats = world.call("get_debug_stats")
	var fps := Engine.get_frames_per_second()
	record_log("[auto] heartbeat")
	record_log("[stats] sim=%s steps=%s time_ms=%s voxels=%s" % [
		str(_last_world_stats.get("sim_mode", "")),
		str(_last_world_stats.get("sim_steps", 0)),
		str(_last_world_stats.get("sim_time_ms", "0")),
		str(_last_world_stats.get("static_voxels", 0))
	])
	record_log("[stats] bricks active=%s occupied=%s indirect=%s" % [
		str(_last_world_stats.get("active_bricks", 0)),
		str(_last_world_stats.get("occupied_bricks", 0)),
		str(_last_world_stats.get("indirect_args", "[]"))
	])
	record_log("[stats] fps=%.1f" % fps)

func record_log(message: String) -> void:
	logs.append(message)
	if logs.size() > max_logs:
		logs.pop_front()
	print(message)
	_append_log_file(message)

func set_stat(key: String, value) -> void:
	stats[key] = value

func attach(world: Node, player: Node, camera: Node, vacuum_target: Node) -> void:
	refs["world"] = world
	refs["player"] = player
	refs["camera"] = camera
	refs["vacuum_target"] = vacuum_target

func get_ref(name: String) -> Variant:
	return refs.get(name, null)

func enable_autopilot(enabled: bool) -> void:
	_autopilot_enabled = enabled
	record_log("[auto] enabled=%s" % str(enabled))

func set_prevent_quit(enabled: bool) -> void:
	_prevent_quit = enabled

func configure_autopilot(interval: float, toggle_gpu: bool, sweep_speed: float, vacuum_rate: float, vacuum_capture: float = 0.8) -> void:
	_autopilot_interval = max(interval, 0.1)
	_autopilot_toggle_gpu = toggle_gpu
	_autopilot_sweep_speed = sweep_speed
	_autopilot_vacuum_rate = vacuum_rate
	_autopilot_vacuum_capture = vacuum_capture

func set_autopilot_output(dir_path: String, dump_interval: float = 2.0) -> void:
	_autopilot_output_dir = dir_path
	_autopilot_dump_interval = max(dump_interval, 0.2)
	_ensure_output_dir()

func _ensure_output_dir() -> void:
	var dir := DirAccess.open(_autopilot_output_dir)
	if dir == null:
		var abs_path := ProjectSettings.globalize_path(_autopilot_output_dir)
		DirAccess.make_dir_recursive_absolute(abs_path)

func _append_log_file(message: String) -> void:
	var path := "%s/log.txt" % _autopilot_output_dir
	var file := FileAccess.open(path, FileAccess.READ_WRITE)
	if file == null:
		file = FileAccess.open(path, FileAccess.WRITE)
		if file == null:
			return
	file.seek_end()
	file.store_line(message)

func _dump_state(frame_id: int) -> void:
	var state := _get_state_snapshot()
	var json := JSON.stringify(state)
	var path := "%s/state_%04d.json" % [_autopilot_output_dir, frame_id]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(json)

func _capture_frame(frame_id: int) -> void:
	var viewport := get_tree().root
	if viewport == null:
		return
	var image := viewport.get_texture().get_image()
	if image == null:
		return
	var path := "%s/frame_%04d.png" % [_autopilot_output_dir, frame_id]
	image.save_png(path)

func _get_state_snapshot() -> Dictionary:
	return {
		"stats": stats.duplicate(true),
		"logs": logs.duplicate(true),
		"autopilot": {
			"enabled": _autopilot_enabled,
			"toggle_gpu": _autopilot_toggle_gpu,
			"interval": _autopilot_interval,
			"dump_interval": _autopilot_dump_interval
		}
	}

func get_stats_text() -> String:
	var lines: Array[String] = []
	for key in stats.keys():
		lines.append("%s: %s" % [key, str(stats[key])])
	return "\n".join(lines)

func get_logs_text() -> String:
	return "\n".join(logs)

func get_state() -> Dictionary:
	return {
		"stats": stats.duplicate(true),
		"logs": logs.duplicate(true),
		"refs": refs.duplicate(true)
	}
