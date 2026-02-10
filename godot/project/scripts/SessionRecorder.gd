extends Node

# Records interactive sessions to repo-local logs so you can share a session ID and we can
# inspect exactly what inputs/settings were applied + how the sim evolved over time.
#
# Output folder:
#   <repo>/runlogs/sessions/<session_id>/
# Files:
#   meta.json
#   events.jsonl
#   mpm_stats.jsonl
#
# Hotkeys:
#   F9 toggles recording
#
# Cmdline:
#   godot --path godot/project -- --record-session <id>

const SESSION_DIR := "runlogs/sessions"

@export var enabled: bool = true
@export var record_input: bool = true
@export var record_mpm_stats: bool = true
@export var stats_poll_hz: float = 30.0

var session_id: String = ""
var _recording: bool = false

var _repo_root_abs: String = ""
var _session_dir_abs: String = ""
var _t0_usec: int = 0

var _events_f: FileAccess
var _stats_f: FileAccess

var _overlay_layer: CanvasLayer
var _overlay_label: Label

var _last_world_rot: Vector3 = Vector3.INF
var _last_gravity_dir: Vector3 = Vector3.INF

var _target_voxel: Node = null
var _target_scene: String = ""
var _stats_accum: float = 0.0
var _last_stats_frame: int = -1
var _saved_stats_enabled: Variant = null
var _saved_stats_every: Variant = null

func is_recording() -> bool:
	return _recording

func _ready() -> void:
	if !enabled:
		return
	_repo_root_abs = _compute_repo_root_abs()
	_install_overlay()
	_parse_cmdline_and_autostart()

func _unhandled_input(event: InputEvent) -> void:
	if !enabled:
		return
	if event is InputEventKey and (event as InputEventKey).pressed and !(event as InputEventKey).echo:
		var k := event as InputEventKey
		var toggle := false
		# Mac laptops often don't expose F-keys; provide a chord.
		# - Cmd+Shift+R (preferred on macOS)
		# - Ctrl+Shift+R (fallback on other keyboards)
		if k.keycode == KEY_F9:
			toggle = true
		elif k.keycode == KEY_R and k.shift_pressed and (k.meta_pressed or k.ctrl_pressed):
			toggle = true
		if toggle:
			if _recording:
				stop_recording()
			else:
				start_recording("")
			get_viewport().set_input_as_handled()
			return

	if !_recording or !record_input:
		return

	# Keep input logging minimal and high-signal: mouse buttons and key presses/releases.
	if event is InputEventMouseButton:
		var e := event as InputEventMouseButton
		_write_event({
			"event": "mouse_button",
			"button": e.button_index,
			"pressed": e.pressed,
			"pos": [e.position.x, e.position.y],
		})
	elif event is InputEventKey:
		var k := event as InputEventKey
		_write_event({
			"event": "key",
			"keycode": int(k.keycode),
			"pressed": k.pressed,
			"shift": k.shift_pressed,
			"ctrl": k.ctrl_pressed,
			"alt": k.alt_pressed,
			"meta": k.meta_pressed,
		})

func start_recording(id: String) -> void:
	if !enabled or _recording:
		return
	session_id = id.strip_edges()
	if session_id.is_empty():
		session_id = _make_session_id()

	_session_dir_abs = _repo_root_abs.path_join(SESSION_DIR).path_join(session_id)
	DirAccess.make_dir_recursive_absolute(_session_dir_abs)

	_events_f = FileAccess.open(_session_dir_abs.path_join("events.jsonl"), FileAccess.WRITE)
	_stats_f = FileAccess.open(_session_dir_abs.path_join("mpm_stats.jsonl"), FileAccess.WRITE)
	_t0_usec = Time.get_ticks_usec()
	_stats_accum = 0.0
	_last_stats_frame = -1

	_target_scene = str(get_tree().current_scene.scene_file_path) if get_tree().current_scene else ""
	_target_voxel = _find_voxel_renderer()

	_write_meta()
	_recording = true
	_set_overlay(true)
	_write_event({"event": "recording_start", "scene": _target_scene})

	# Ensure the renderer produces stats frequently enough to observe behavior.
	if _target_voxel != null and record_mpm_stats:
		_saved_stats_enabled = _safe_get(_target_voxel, "mpm_stats_enabled")
		_saved_stats_every = _safe_get(_target_voxel, "mpm_stats_every")
		_safe_set(_target_voxel, "mpm_stats_enabled", true)
		_safe_set(_target_voxel, "mpm_stats_every", 1)

func stop_recording() -> void:
	if !_recording:
		return
	_write_event({"event": "recording_stop"})

	# Restore prior renderer settings.
	if _target_voxel != null and record_mpm_stats:
		if _saved_stats_enabled != null:
			_safe_set(_target_voxel, "mpm_stats_enabled", _saved_stats_enabled)
		if _saved_stats_every != null:
			_safe_set(_target_voxel, "mpm_stats_every", _saved_stats_every)

	_recording = false
	_set_overlay(false)

	if _events_f:
		_events_f.flush()
		_events_f = null
	if _stats_f:
		_stats_f.flush()
		_stats_f = null

func record_spawn(material_id: int, cells: Array) -> void:
	# Called by PaintController.
	if !_recording:
		return
	var out_cells: Array = []
	# Keep payload size bounded. Record a sample + count.
	var max_cells := 512
	for i in range(min(cells.size(), max_cells)):
		var c = cells[i]
		if typeof(c) == TYPE_VECTOR3I:
			out_cells.append([c.x, c.y, c.z])
	_write_event({
		"event": "spawn",
		"material": int(material_id),
		"count": int(cells.size()),
		"cells": out_cells,
		"truncated": cells.size() > max_cells,
	})

func record_controls(world_rotation: Vector3, gravity_dir: Vector3) -> void:
	# Called by SceneControls when sliders apply.
	if !_recording:
		return
	_write_event({
		"event": "controls",
		"world_rotation": [world_rotation.x, world_rotation.y, world_rotation.z],
		"gravity_dir": [gravity_dir.x, gravity_dir.y, gravity_dir.z],
	})

func _process(delta: float) -> void:
	if !_recording:
		return

	# Scene switches: re-bind target node and write an event.
	var cur_scene_path := str(get_tree().current_scene.scene_file_path) if get_tree().current_scene else ""
	if cur_scene_path != _target_scene:
		_target_scene = cur_scene_path
		_bind_voxel_renderer(_find_voxel_renderer())
		_write_event({"event": "scene_change", "scene": _target_scene})
	elif _target_voxel == null:
		# Late-binding in case the scene is still constructing nodes.
		_bind_voxel_renderer(_find_voxel_renderer())

	# Record high-level controls if they change, even if the scene doesn't use SceneControls.
	if _target_voxel != null:
		var wr: Variant = _safe_get(_target_voxel, "world_rotation")
		var gd: Variant = _safe_get(_target_voxel, "gravity_dir")
		if typeof(wr) == TYPE_VECTOR3:
			var v := wr as Vector3
			if _last_world_rot == Vector3.INF or v.distance_to(_last_world_rot) > 1e-4:
				_last_world_rot = v
				_write_event({"event": "world_rotation", "value": [v.x, v.y, v.z]})
		if typeof(gd) == TYPE_VECTOR3:
			var g := gd as Vector3
			if _last_gravity_dir == Vector3.INF or g.distance_to(_last_gravity_dir) > 1e-4:
				_last_gravity_dir = g
				_write_event({"event": "gravity_dir", "value": [g.x, g.y, g.z]})

	# Stats polling (reads cached stats; avoids GPU readback storms).
	if record_mpm_stats and _target_voxel != null:
		_stats_accum += maxf(0.0, delta)
		var period := 1.0 / maxf(1.0, stats_poll_hz)
		if _stats_accum >= period:
			_stats_accum = 0.0
			_poll_stats()

func _bind_voxel_renderer(n: Node) -> void:
	if n == _target_voxel:
		return
	# Restore prior renderer settings if we changed them.
	if _target_voxel != null and record_mpm_stats:
		if _saved_stats_enabled != null:
			_safe_set(_target_voxel, "mpm_stats_enabled", _saved_stats_enabled)
		if _saved_stats_every != null:
			_safe_set(_target_voxel, "mpm_stats_every", _saved_stats_every)
	_saved_stats_enabled = null
	_saved_stats_every = null
	_target_voxel = n
	_last_world_rot = Vector3.INF
	_last_gravity_dir = Vector3.INF
	_last_stats_frame = -1
	if _target_voxel != null and record_mpm_stats:
		_saved_stats_enabled = _safe_get(_target_voxel, "mpm_stats_enabled")
		_saved_stats_every = _safe_get(_target_voxel, "mpm_stats_every")
		_safe_set(_target_voxel, "mpm_stats_enabled", true)
		_safe_set(_target_voxel, "mpm_stats_every", 1)

func _poll_stats() -> void:
	if _target_voxel == null:
		return
	if !_target_voxel.has_method("mpm_get_last_stats_frame") or !_target_voxel.has_method("mpm_get_last_stats_raw"):
		return
	var frame_v: Variant = _target_voxel.call("mpm_get_last_stats_frame")
	var frame := int(frame_v) if typeof(frame_v) in [TYPE_INT, TYPE_FLOAT] else 0
	if frame <= _last_stats_frame:
		return
	_last_stats_frame = frame
	var raw: Variant = _target_voxel.call("mpm_get_last_stats_raw")
	if typeof(raw) != TYPE_PACKED_INT32_ARRAY and typeof(raw) != TYPE_ARRAY:
		return
	var arr: Array = []
	if typeof(raw) == TYPE_PACKED_INT32_ARRAY:
		for x in raw:
			arr.append(int(x))
	else:
		for x in raw as Array:
			arr.append(int(x))
	_write_stats({
		"stats_frame": frame,
		"raw": arr,
	})

func _write_meta() -> void:
	var meta := {
		"session_id": session_id,
		"started_unix_s": int(Time.get_unix_time_from_system()),
		"engine_version": Engine.get_version_info(),
		"os": OS.get_name(),
		"project_dir": ProjectSettings.globalize_path("res://"),
		"repo_root": _repo_root_abs,
		"scene": _target_scene,
	}
	var f := FileAccess.open(_session_dir_abs.path_join("meta.json"), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(meta, "  "))
		f.flush()

func _write_event(obj: Dictionary) -> void:
	if !_events_f:
		return
	obj["t_ms"] = float(Time.get_ticks_usec() - _t0_usec) / 1000.0
	obj["frame"] = int(Engine.get_process_frames())
	_events_f.store_line(JSON.stringify(obj))
	_events_f.flush()

func _write_stats(obj: Dictionary) -> void:
	if !_stats_f:
		return
	obj["t_ms"] = float(Time.get_ticks_usec() - _t0_usec) / 1000.0
	obj["frame"] = int(Engine.get_process_frames())
	_stats_f.store_line(JSON.stringify(obj))
	_stats_f.flush()

func _install_overlay() -> void:
	_overlay_layer = CanvasLayer.new()
	_overlay_layer.layer = 1000
	_overlay_label = Label.new()
	_overlay_label.position = Vector2(16, 8)
	_overlay_label.text = ""
	_overlay_label.add_theme_font_size_override("font_size", 14)
	_overlay_layer.add_child(_overlay_label)
	# Root can be "busy setting up children" during early startup, especially headless/automation.
	get_tree().get_root().add_child.call_deferred(_overlay_layer)
	_set_overlay(false)

func _set_overlay(on: bool) -> void:
	if _overlay_label == null:
		return
	_overlay_layer.visible = on
	if on:
		_overlay_label.text = "REC %s\\n%s" % [session_id, _session_dir_abs]

func _parse_cmdline_and_autostart() -> void:
	var args := OS.get_cmdline_user_args()
	var rid := ""
	for i in range(args.size()):
		if str(args[i]) == "--record-session" and (i + 1) < args.size():
			rid = str(args[i + 1])
			break
	if !rid.is_empty():
		start_recording(rid)

func _find_voxel_renderer() -> Node:
	var root := get_tree().get_root()
	if root == null:
		return null
	var n := root.find_child("VoxelRenderer", true, false)
	return n

func _compute_repo_root_abs() -> String:
	var project_abs := ProjectSettings.globalize_path("res://").rstrip("/")
	# project_abs = <repo>/godot/project
	var a := project_abs.get_base_dir() # <repo>/godot
	var b := a.get_base_dir()           # <repo>
	return b

func _make_session_id() -> String:
	var unix := int(Time.get_unix_time_from_system())
	var pid := int(OS.get_process_id())
	var r := int(randi() & 0xffff)
	return "%d-%d-%04x" % [unix, pid, r]

func _safe_get(node: Node, prop: String) -> Variant:
	if node == null:
		return null
	if node.has_method("get"):
		return node.get(prop)
	return null

func _safe_set(node: Node, prop: String, val: Variant) -> void:
	if node == null:
		return
	if node.has_method("set"):
		node.set(prop, val)
