extends Node3D

const MaterialRegistry = preload("res://scripts/MaterialRegistry.gd")

@export var voxel_renderer_path: NodePath
@export var player_path: NodePath
@export var camera_path: NodePath
@export var overlay_path: NodePath
@export var hotbar_slots_path: NodePath
@export var hub_scene: String = "res://scenes/ProtoHub.tscn"

@export var move_speed: float = 18.0
@export var sprint_multiplier: float = 1.8
@export var vertical_speed: float = 14.0
@export var enable_fly_controls: bool = false
@export var mouse_sensitivity: float = 0.0024
@export var max_reach_world: float = 14.0
@export var keep_player_grounded: bool = true
@export var ground_clearance_cells: float = 2.4
@export var ground_snap_speed: float = 16.0
@export var ground_probe_radius_cells: int = 1
@export var controller_move_deadzone: float = 0.18
@export var controller_look_deadzone: float = 0.14
@export var controller_look_sensitivity: float = 2.4
@export var enable_controller_triggers: bool = true
@export var controller_trigger_threshold: float = 0.55

@export var chunk_radius_cells: int = 22
@export var base_y: int = 4
@export var terrain_height: int = 10
@export var top_material_id: int = 1
@export var fill_material_id: int = 4

@export var default_place_material: int = 4
@export var alt_place_material: int = 1
@export var fluid_place_material: int = 2
@export var spawn_demo_physics: bool = true
@export var demo_sand_material_id: int = 1
@export var demo_water_material_id: int = 2
@export var hotbar_size: int = 9
@export var starter_stack_count: int = 0
@export var fire_inventory_slot_material_id: int = MaterialRegistry.FIRE_ID
@export var fire_inventory_count: int = 99

var _renderer: Node = null
var _player: Node3D = null
var _camera: Camera3D = null
var _overlay: Label = null
var _hotbar_slots: HBoxContainer = null
var _hotbar_slot_panels: Array = []
var _hotbar_slot_labels: Array = []

var _yaw: float = 0.0
var _pitch: float = 0.0
var _held_material: int = 4
var _active_slot: int = 0
var _init_attempts: int = 0
var _last_scan: Dictionary = {}
var _hotbar_materials: Array = []
var _inventory_counts: Dictionary = {}
var _controller_pickup_down: bool = false
var _controller_place_down: bool = false

func _ready() -> void:
    _renderer = get_node_or_null(voxel_renderer_path)
    _player = get_node_or_null(player_path) as Node3D
    _camera = get_node_or_null(camera_path) as Camera3D
    _overlay = get_node_or_null(overlay_path) as Label
    _hotbar_slots = get_node_or_null(hotbar_slots_path) as HBoxContainer
    if _renderer == null or _player == null or _camera == null:
        push_error("VoxelGameController missing required scene references.")
        return
    _held_material = default_place_material
    _setup_inventory()
    _build_hotbar_ui()
    _refresh_hotbar_ui()
    call_deferred("_initialize_scene")

func _initialize_scene() -> void:
    if _renderer == null:
        return
    if _renderer.has_method("is_render_ready") and !_renderer.is_render_ready():
        _init_attempts += 1
        if _init_attempts <= 180:
            call_deferred("_initialize_scene")
        else:
            push_error("VoxelGameController renderer was not ready in time.")
        return
    _init_attempts = 0
    _renderer.world_rotation = Vector3.ZERO
    _renderer.gravity_dir = Vector3(0.0, -1.0, 0.0)

    _build_chunk_world()
    _spawn_player_above_chunk()
    if keep_player_grounded:
        _snap_player_to_ground(0.0, true)

    _capture_mouse()
    _apply_view_rotation()
    _last_scan = _raycast_from_camera()
    _apply_preview(_last_scan)
    _update_overlay(_last_scan)

func _unhandled_input(event: InputEvent) -> void:
    var vp := get_viewport()
    if vp == null:
        return
    if event.is_action_pressed("ui_cancel"):
        if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
            _release_mouse()
        else:
            get_tree().change_scene_to_file(hub_scene)
        vp.set_input_as_handled()
        return

    if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
        var mm := event as InputEventMouseMotion
        _yaw -= mm.relative.x * mouse_sensitivity
        _pitch = clamp(_pitch - mm.relative.y * mouse_sensitivity, deg_to_rad(-89.0), deg_to_rad(89.0))
        _apply_view_rotation()
        vp.set_input_as_handled()
        return

    if event is InputEventMouseButton and event.pressed:
        var mb := event as InputEventMouseButton
        if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
            if mb.button_index == MOUSE_BUTTON_LEFT:
                _capture_mouse()
                vp.set_input_as_handled()
            return
        if mb.button_index == MOUSE_BUTTON_LEFT:
            _pickup_block()
            vp.set_input_as_handled()
            return
        if mb.button_index == MOUSE_BUTTON_RIGHT:
            _place_block()
            vp.set_input_as_handled()
            return

    if event is InputEventKey and event.pressed and !event.echo:
        var key_ev := event as InputEventKey
        var slot_idx: int = _slot_index_from_keycode(key_ev.keycode)
        if slot_idx >= 0:
            _set_active_slot(slot_idx)
            vp.set_input_as_handled()
            return

    if event is InputEventJoypadButton and event.pressed:
        var jb := event as InputEventJoypadButton
        match jb.button_index:
            JOY_BUTTON_DPAD_LEFT, JOY_BUTTON_LEFT_SHOULDER:
                _cycle_active_slot(-1)
                vp.set_input_as_handled()
                return
            JOY_BUTTON_DPAD_RIGHT, JOY_BUTTON_RIGHT_SHOULDER:
                _cycle_active_slot(1)
                vp.set_input_as_handled()
                return

func _physics_process(delta: float) -> void:
    if _renderer == null or _player == null:
        return
    _update_controller_look(delta)
    _update_movement(delta)
    _last_scan = _raycast_from_camera()
    _apply_preview(_last_scan)
    _handle_controller_triggers()
    _update_overlay(_last_scan)

func _update_movement(delta: float) -> void:
    var move_x := 0.0
    var move_z := 0.0
    var move_y := 0.0

    if Input.is_physical_key_pressed(KEY_A):
        move_x -= 1.0
    if Input.is_physical_key_pressed(KEY_D):
        move_x += 1.0
    # Positive move_z follows the player's forward vector. This keeps W/S intuitive.
    if Input.is_physical_key_pressed(KEY_W):
        move_z += 1.0
    if Input.is_physical_key_pressed(KEY_S):
        move_z -= 1.0

    var joy_id: int = _active_joypad_id()
    if joy_id >= 0:
        move_x += _read_axis_with_deadzone(joy_id, JOY_AXIS_LEFT_X, controller_move_deadzone)
        move_z += -_read_axis_with_deadzone(joy_id, JOY_AXIS_LEFT_Y, controller_move_deadzone)
    if enable_fly_controls:
        if Input.is_physical_key_pressed(KEY_SPACE):
            move_y += 1.0
        if Input.is_physical_key_pressed(KEY_CTRL) or Input.is_physical_key_pressed(KEY_C):
            move_y -= 1.0

    var move_h := Vector2(move_x, move_z)
    if move_h.length() > 1.0:
        move_h = move_h.normalized()

    var speed := move_speed
    if Input.is_physical_key_pressed(KEY_SHIFT):
        speed *= sprint_multiplier

    var basis := _player.global_transform.basis
    var forward := -basis.z
    var right := basis.x
    forward.y = 0.0
    right.y = 0.0
    if forward.length() > 0.0:
        forward = forward.normalized()
    if right.length() > 0.0:
        right = right.normalized()

    var world_move := right * move_h.x + forward * move_h.y
    if world_move.length() > 0.0:
        _player.global_position += world_move.normalized() * speed * delta

    if enable_fly_controls and abs(move_y) > 0.0:
        _player.global_position += Vector3.UP * move_y * vertical_speed * delta

    if keep_player_grounded and !enable_fly_controls:
        _snap_player_to_ground(delta, false)

func _capture_mouse() -> void:
    Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _release_mouse() -> void:
    Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func _apply_view_rotation() -> void:
    if _player == null or _camera == null:
        return
    _player.rotation = Vector3(0.0, _yaw, 0.0)
    _camera.rotation = Vector3(_pitch, 0.0, 0.0)

func _build_chunk_world() -> void:
    if _renderer == null:
        return
    var grid_extent: int = int(_renderer.chunk_grid) * int(_renderer.chunk_size)
    var center: int = int((grid_extent - 1) / 2)
    var radius := clampi(chunk_radius_cells, 4, center - 2)
    var min_x := maxi(1, center - radius)
    var max_x := mini(grid_extent - 2, center + radius)
    var min_z := maxi(1, center - radius)
    var max_z := mini(grid_extent - 2, center + radius)
    var entries: Array = []

    for z in range(min_z, max_z + 1):
        for x in range(min_x, max_x + 1):
            var y_top := _terrain_height_for(x, z, center, grid_extent)
            for y in range(0, y_top + 1):
                if !_is_bcc_cell(x, y, z):
                    continue
                var mat := fill_material_id
                if y >= y_top - 1:
                    mat = top_material_id
                entries.append({"pos": Vector3(x, y, z), "material": mat})

    if spawn_demo_physics:
        _append_demo_blob(entries, Vector3i(center - 6, base_y + terrain_height + 14, center), 4, demo_sand_material_id, grid_extent)
        _append_demo_blob(entries, Vector3i(center + 7, base_y + terrain_height + 16, center), 3, demo_water_material_id, grid_extent)

    if _renderer.has_method("set_voxel_entries"):
        _renderer.set_voxel_entries(entries, true)

func _terrain_height_for(x: int, z: int, center: int, grid_extent: int) -> int:
    var dx := float(x - center)
    var dz := float(z - center)
    var radial: float = clamp(1.0 - Vector2(dx, dz).length() / max(1.0, float(chunk_radius_cells)), 0.0, 1.0)
    var waves: float = sin(dx * 0.22) * 2.5 + cos(dz * 0.18) * 2.0
    var y_top: int = base_y + int(round(float(terrain_height) * radial + waves))
    return clampi(y_top, 2, grid_extent - 6)

func _spawn_player_above_chunk() -> void:
    if _renderer == null or _player == null:
        return
    var grid_extent: int = int(_renderer.chunk_grid) * int(_renderer.chunk_size)
    var center: int = int((grid_extent - 1) / 2)
    var surface_y := 2
    for y in range(grid_extent - 1, -1, -1):
        if !_is_bcc_cell(center, y, center):
            continue
        if int(_renderer.get_cell_material(Vector3i(center, y, center))) != 0:
            surface_y = y
            break
    var spawn_cell := _snap_to_bcc(Vector3i(center, surface_y + 6, center), grid_extent)
    if spawn_cell.x < 0:
        spawn_cell = Vector3i(center, surface_y + 6, center)
    _player.global_position = _cell_to_world(spawn_cell, grid_extent, float(_renderer.lattice_spacing))

func _pickup_block() -> void:
    if _renderer == null:
        return
    var hit := _raycast_from_camera()
    if !bool(hit.get("hit", false)):
        return
    var hit_cell := hit.get("hit_cell", Vector3i(-1, -1, -1)) as Vector3i
    if hit_cell.x < 0:
        return
    var mat := int(hit.get("material", 0))
    if mat == 0:
        return
    _renderer.set_voxel_at(hit_cell, 0)
    _inventory_add(mat, 1)
    _ensure_material_on_hotbar(mat)
    _last_scan = hit
    _refresh_hotbar_ui()
    _apply_preview(hit)
    _update_overlay(hit)

func _place_block() -> void:
    if _renderer == null:
        return
    var mat_id: int = _active_slot_material()
    if mat_id <= 0:
        return
    if _inventory_get(mat_id) <= 0:
        return
    var hit := _raycast_from_camera()
    var place_cell := hit.get("empty_cell", Vector3i(-1, -1, -1)) as Vector3i
    if place_cell.x < 0:
        return
    if int(_renderer.get_cell_material(place_cell)) != 0:
        return
    _renderer.set_voxel_at(place_cell, mat_id)
    _inventory_add(mat_id, -1)
    if _inventory_get(mat_id) <= 0:
        _hotbar_materials[_active_slot] = 0
    _held_material = _active_slot_material()
    _last_scan = hit
    _refresh_hotbar_ui()
    _apply_preview(hit)
    _update_overlay(hit)

func _apply_preview(hit: Dictionary) -> void:
    if _renderer == null:
        return
    var cursor := Vector3i(-1, -1, -1)
    var preview: Array = []
    if bool(hit.get("hit", false)):
        cursor = hit.get("hit_cell", Vector3i(-1, -1, -1))
        var place_cell := hit.get("empty_cell", Vector3i(-1, -1, -1)) as Vector3i
        if place_cell.x >= 0:
            preview.append(place_cell)
    if _renderer.has_method("set_cursor_cell"):
        _renderer.set_cursor_cell(cursor)
    if _renderer.has_method("set_preview_cells"):
        _renderer.set_preview_cells(preview)

func _update_overlay(hit: Dictionary) -> void:
    if _overlay == null:
        return
    var capture_hint := "Captured" if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED else "Released (left click or RT to capture)"
    var target := "none"
    if bool(hit.get("hit", false)):
        target = _material_name(int(hit.get("material", 0)))
    var movement_hint := "WASD/LS move | Mouse/RS look | Shift sprint | Esc release/back"
    if enable_fly_controls:
        movement_hint = "WASD/LS move | Mouse/RS look | Shift sprint | Space/Ctrl vertical | Esc release/back"
    var held_mat: int = _active_slot_material()
    var held_count: int = _inventory_get(held_mat)
    _overlay.text = (
        "Voxel Game Prototype\n"
        + movement_hint + "\n"
        + "Left click pickup | Right click place | RT pickup | LT place | Number keys/D-pad/LB/RB select hotbar slot\n"
        + "Active Slot: %d  |  Held: %s x%d  |  Target: %s  |  Mouse: %s"
    ) % [_active_slot + 1, _material_name(held_mat), held_count, target, capture_hint]

func _update_controller_look(delta: float) -> void:
    var joy_id: int = _active_joypad_id()
    if joy_id < 0:
        return
    var look_x: float = _read_axis_with_deadzone(joy_id, JOY_AXIS_RIGHT_X, controller_look_deadzone)
    var look_y: float = _read_axis_with_deadzone(joy_id, JOY_AXIS_RIGHT_Y, controller_look_deadzone)
    if abs(look_x) < 0.0001 and abs(look_y) < 0.0001:
        return
    if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
        _capture_mouse()
    _yaw -= look_x * controller_look_sensitivity * delta
    _pitch = clamp(_pitch - look_y * controller_look_sensitivity * delta, deg_to_rad(-89.0), deg_to_rad(89.0))
    _apply_view_rotation()

func _handle_controller_triggers() -> void:
    if !enable_controller_triggers:
        _controller_pickup_down = false
        _controller_place_down = false
        return
    var joy_id: int = _active_joypad_id()
    if joy_id < 0:
        _controller_pickup_down = false
        _controller_place_down = false
        return
    var pickup_now: bool = _read_trigger_strength(joy_id, JOY_AXIS_TRIGGER_RIGHT) >= controller_trigger_threshold
    var place_now: bool = _read_trigger_strength(joy_id, JOY_AXIS_TRIGGER_LEFT) >= controller_trigger_threshold
    if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
        if pickup_now and !_controller_pickup_down:
            _capture_mouse()
        _controller_pickup_down = pickup_now
        _controller_place_down = place_now
        return
    if pickup_now and !_controller_pickup_down:
        _pickup_block()
    if place_now and !_controller_place_down:
        _place_block()
    _controller_pickup_down = pickup_now
    _controller_place_down = place_now

func _active_joypad_id() -> int:
    var joypads: PackedInt32Array = Input.get_connected_joypads()
    if joypads.is_empty():
        return -1
    return int(joypads[0])

func _read_trigger_strength(joy_id: int, axis: int) -> float:
    var raw: float = Input.get_joy_axis(joy_id, axis)
    if raw < 0.0:
        raw = (raw + 1.0) * 0.5
    return clamp(raw, 0.0, 1.0)

func _read_axis_with_deadzone(joy_id: int, axis: int, deadzone: float) -> float:
    var dz: float = clamp(deadzone, 0.0, 0.95)
    var raw: float = clamp(Input.get_joy_axis(joy_id, axis), -1.0, 1.0)
    var mag: float = abs(raw)
    if mag <= dz:
        return 0.0
    var scaled: float = (mag - dz) / (1.0 - dz)
    return sign(raw) * scaled

func _material_name(material_id: int) -> String:
    match material_id:
        1:
            return "Sand (1)"
        2:
            return "Water (2)"
        6:
            return "Metal (6)"
        5:
            return "Fire (5)"
        4:
            return "Stone (4)"
        8:
            return "Glass (8)"
        9:
            return "Invisible (9)"
        _:
            return "Mat %d" % material_id

func _raycast_from_camera() -> Dictionary:
    var out := {
        "hit": false,
        "hit_cell": Vector3i(-1, -1, -1),
        "empty_cell": Vector3i(-1, -1, -1),
        "material": 0,
    }
    if _renderer == null or _camera == null or !_renderer.has_method("get_cell_material"):
        return out

    var grid_extent: int = int(_renderer.chunk_grid) * int(_renderer.chunk_size)
    var spacing: float = float(_renderer.lattice_spacing)
    var world_extent: float = float(grid_extent) * spacing
    var origin := Vector3(-0.5 * world_extent, -0.5 * world_extent, -0.5 * world_extent)
    var world_basis := Basis.from_euler(_renderer.world_rotation as Vector3)
    var inv_world := world_basis.transposed()
    var world_center := origin + Vector3.ONE * (0.5 * world_extent)

    var ro_world := _camera.global_transform.origin
    var rd_world := -_camera.global_transform.basis.z
    if rd_world.length() <= 1e-6:
        return out
    rd_world = rd_world.normalized()

    var ro_local := world_center + inv_world * (ro_world - world_center)
    var rd_local := (inv_world * rd_world).normalized()
    var bmin := origin
    var bmax := origin + Vector3.ONE * world_extent
    var range := _ray_aabb_range(ro_local, rd_local, bmin, bmax)
    if range.x >= 1e19:
        return out

    var t: float = max(range.x, 0.0) + 1e-4
    var t_end: float = min(range.y, t + max_reach_world)
    if t > t_end:
        return out

    var p: Vector3 = ro_local + rd_local * t
    var grid_pos: Vector3 = (p - origin) / spacing
    var cell := Vector3i(floor(grid_pos.x), floor(grid_pos.y), floor(grid_pos.z))

    var step := Vector3i(
        1 if rd_local.x > 0.0 else (-1 if rd_local.x < 0.0 else 0),
        1 if rd_local.y > 0.0 else (-1 if rd_local.y < 0.0 else 0),
        1 if rd_local.z > 0.0 else (-1 if rd_local.z < 0.0 else 0)
    )
    var next_boundary := Vector3(
        float(cell.x + (1 if step.x > 0 else 0)),
        float(cell.y + (1 if step.y > 0 else 0)),
        float(cell.z + (1 if step.z > 0 else 0))
    )
    var dx_safe := rd_local.x if abs(rd_local.x) > 1e-6 else 1e-6
    var dy_safe := rd_local.y if abs(rd_local.y) > 1e-6 else 1e-6
    var dz_safe := rd_local.z if abs(rd_local.z) > 1e-6 else 1e-6
    var t_max := Vector3(
        (next_boundary.x - grid_pos.x) / dx_safe,
        (next_boundary.y - grid_pos.y) / dy_safe,
        (next_boundary.z - grid_pos.z) / dz_safe
    )
    var t_delta := Vector3(
        1.0 / abs(dx_safe),
        1.0 / abs(dy_safe),
        1.0 / abs(dz_safe)
    )

    var last_empty := Vector3i(-1, -1, -1)
    var last_sampled := Vector3i(-9999, -9999, -9999)
    var safety := 0
    while t <= t_end and safety < 512:
        safety += 1
        if cell.x < 0 or cell.y < 0 or cell.z < 0 or cell.x >= grid_extent or cell.y >= grid_extent or cell.z >= grid_extent:
            break
        var sample_cell := _snap_to_bcc(cell, grid_extent)
        if sample_cell.x >= 0 and sample_cell != last_sampled:
            last_sampled = sample_cell
            var mat := int(_renderer.get_cell_material(sample_cell))
            if mat != 0:
                out["hit"] = true
                out["hit_cell"] = sample_cell
                out["empty_cell"] = last_empty
                out["material"] = mat
                return out
            last_empty = sample_cell

        if t_max.x < t_max.y:
            if t_max.x < t_max.z:
                cell.x += step.x
                t = t_max.x
                t_max.x += t_delta.x
            else:
                cell.z += step.z
                t = t_max.z
                t_max.z += t_delta.z
        else:
            if t_max.y < t_max.z:
                cell.y += step.y
                t = t_max.y
                t_max.y += t_delta.y
            else:
                cell.z += step.z
                t = t_max.z
                t_max.z += t_delta.z

    out["empty_cell"] = last_empty
    return out

func _cell_to_world(cell: Vector3i, grid_extent: int, spacing: float) -> Vector3:
    var world_extent := float(grid_extent) * spacing
    var origin := Vector3(-0.5 * world_extent, -0.5 * world_extent, -0.5 * world_extent)
    var local_pos := origin + Vector3(cell) * spacing
    var basis := Basis.from_euler(_renderer.world_rotation as Vector3)
    var center := origin + Vector3.ONE * (0.5 * world_extent)
    return center + basis * (local_pos - center)

func _ray_aabb_range(ro: Vector3, rd: Vector3, bmin: Vector3, bmax: Vector3) -> Vector2:
    var tmin := -1e9
    var tmax := 1e9
    for axis in [0, 1, 2]:
        var o: float = ro[axis]
        var d: float = rd[axis]
        var minv: float = bmin[axis]
        var maxv: float = bmax[axis]
        if abs(d) < 1e-6:
            if o < minv or o > maxv:
                return Vector2(1e20, 1e20)
            continue
        var inv := 1.0 / d
        var t1 := (minv - o) * inv
        var t2 := (maxv - o) * inv
        if t1 > t2:
            var tmp := t1
            t1 = t2
            t2 = tmp
        tmin = max(tmin, t1)
        tmax = min(tmax, t2)
        if tmin > tmax:
            return Vector2(1e20, 1e20)
    return Vector2(tmin, tmax)

func _snap_to_bcc(cell: Vector3i, grid_extent: int) -> Vector3i:
    var cand := _nearest_bcc(Vector3(cell))
    if cand.x < 0 or cand.y < 0 or cand.z < 0 or cand.x >= grid_extent or cand.y >= grid_extent or cand.z >= grid_extent:
        return Vector3i(-1, -1, -1)
    return cand

func _nearest_bcc(pos: Vector3) -> Vector3i:
    var base := Vector3i(floor(pos.x), floor(pos.y), floor(pos.z))
    var best := base
    var best_dist := 1e20
    for dz in range(2):
        for dy in range(2):
            for dx in range(2):
                var cand := base + Vector3i(dx, dy, dz)
                if !_is_bcc_cell(cand.x, cand.y, cand.z):
                    continue
                var d := (pos - Vector3(cand)).length_squared()
                if d < best_dist:
                    best_dist = d
                    best = cand
    return best

func _is_bcc_cell(x: int, y: int, z: int) -> bool:
    return ((x & 1) == (y & 1)) and ((y & 1) == (z & 1))

func _append_demo_blob(entries: Array, center_cell: Vector3i, radius: int, material_id: int, grid_extent: int) -> void:
    if material_id <= 0:
        return
    var r := maxi(1, radius)
    var r2 := r * r
    for dz in range(-r, r + 1):
        for dy in range(-r, r + 1):
            for dx in range(-r, r + 1):
                if dx * dx + dy * dy + dz * dz > r2:
                    continue
                var c := center_cell + Vector3i(dx, dy, dz)
                if c.x < 1 or c.y < 1 or c.z < 1 or c.x >= grid_extent - 1 or c.y >= grid_extent - 1 or c.z >= grid_extent - 1:
                    continue
                if !_is_bcc_cell(c.x, c.y, c.z):
                    continue
                entries.append({"pos": Vector3(c), "material": material_id})

func _setup_inventory() -> void:
    _inventory_counts.clear()
    _hotbar_materials = []
    var slots: int = clampi(hotbar_size, 1, 9)
    for i in range(slots):
        _hotbar_materials.append(0)

    var defaults: Array = [default_place_material, alt_place_material, fluid_place_material]
    var write_idx: int = 0
    for m in defaults:
        var mid: int = int(m)
        if mid <= 0:
            continue
        var exists: bool = false
        for i in range(_hotbar_materials.size()):
            if int(_hotbar_materials[i]) == mid:
                exists = true
                break
        if exists:
            continue
        if write_idx >= _hotbar_materials.size():
            break
        _hotbar_materials[write_idx] = mid
        write_idx += 1
        if starter_stack_count > 0:
            _inventory_counts[mid] = starter_stack_count

    var fire_mid: int = fire_inventory_slot_material_id
    if fire_mid > 0 and _hotbar_materials.size() > 0:
        var last_slot_idx: int = _hotbar_materials.size() - 1
        _hotbar_materials[last_slot_idx] = fire_mid
        var fire_count: int = maxi(0, fire_inventory_count)
        if fire_count > 0:
            _inventory_counts[fire_mid] = maxi(int(_inventory_counts.get(fire_mid, 0)), fire_count)

    _active_slot = 0
    _held_material = _active_slot_material()

func _build_hotbar_ui() -> void:
    if _hotbar_slots == null:
        return
    for c in _hotbar_slots.get_children():
        c.queue_free()
    _hotbar_slot_panels.clear()
    _hotbar_slot_labels.clear()

    for i in range(_hotbar_materials.size()):
        var panel := PanelContainer.new()
        panel.custom_minimum_size = Vector2(70.0, 56.0)

        var label := Label.new()
        label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
        label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
        label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        label.custom_minimum_size = Vector2(66.0, 52.0)

        panel.add_child(label)
        _hotbar_slots.add_child(panel)
        _hotbar_slot_panels.append(panel)
        _hotbar_slot_labels.append(label)

func _refresh_hotbar_ui() -> void:
    if _hotbar_slots == null:
        return
    var slot_count: int = mini(_hotbar_materials.size(), _hotbar_slot_labels.size())
    for i in range(slot_count):
        var mat_id: int = int(_hotbar_materials[i])
        var count: int = _inventory_get(mat_id)
        var title: String = "-"
        if mat_id > 0:
            title = _material_short_name(mat_id)
        var slot_label := "[%d]" % (i + 1) if i == _active_slot else "%d" % (i + 1)
        var txt := "%s\n%s\n%d" % [slot_label, title, count]
        var label: Label = _hotbar_slot_labels[i] as Label
        var panel: PanelContainer = _hotbar_slot_panels[i] as PanelContainer
        if label != null:
            label.text = txt
            label.self_modulate = Color(1.0, 1.0, 1.0, 1.0) if i == _active_slot else Color(0.85, 0.85, 0.85, 1.0)
            label.add_theme_color_override("font_color", Color(1.0, 0.98, 0.90, 1.0) if i == _active_slot else Color(0.88, 0.88, 0.88, 1.0))
        if panel != null:
            panel.self_modulate = Color(1.0, 1.0, 1.0, 1.0)
            var style := StyleBoxFlat.new()
            style.corner_radius_top_left = 6
            style.corner_radius_top_right = 6
            style.corner_radius_bottom_right = 6
            style.corner_radius_bottom_left = 6
            style.border_width_left = 3 if i == _active_slot else 1
            style.border_width_top = 3 if i == _active_slot else 1
            style.border_width_right = 3 if i == _active_slot else 1
            style.border_width_bottom = 3 if i == _active_slot else 1
            style.border_color = Color(1.0, 0.84, 0.34, 1.0) if i == _active_slot else Color(0.42, 0.42, 0.42, 1.0)
            style.bg_color = Color(0.25, 0.20, 0.12, 0.95) if i == _active_slot else Color(0.11, 0.11, 0.11, 0.88)
            panel.add_theme_stylebox_override("panel", style)

func _slot_index_from_keycode(keycode: Key) -> int:
    match keycode:
        KEY_1:
            return 0
        KEY_2:
            return 1
        KEY_3:
            return 2
        KEY_4:
            return 3
        KEY_5:
            return 4
        KEY_6:
            return 5
        KEY_7:
            return 6
        KEY_8:
            return 7
        KEY_9:
            return 8
        _:
            return -1

func _set_active_slot(slot_idx: int) -> void:
    if slot_idx < 0 or slot_idx >= _hotbar_materials.size():
        return
    _active_slot = slot_idx
    _held_material = _active_slot_material()
    _refresh_hotbar_ui()

func _cycle_active_slot(step: int) -> void:
    var slot_count: int = _hotbar_materials.size()
    if slot_count <= 0:
        return
    var dir: int = 1 if step >= 0 else -1
    var next_idx: int = posmod(_active_slot + dir, slot_count)
    _set_active_slot(next_idx)

func _active_slot_material() -> int:
    if _active_slot < 0 or _active_slot >= _hotbar_materials.size():
        return 0
    return int(_hotbar_materials[_active_slot])

func _inventory_get(mat_id: int) -> int:
    if mat_id <= 0:
        return 0
    return int(_inventory_counts.get(mat_id, 0))

func _inventory_add(mat_id: int, delta: int) -> void:
    if mat_id <= 0 or delta == 0:
        return
    var next: int = _inventory_get(mat_id) + delta
    if next <= 0:
        _inventory_counts.erase(mat_id)
    else:
        _inventory_counts[mat_id] = next

func _ensure_material_on_hotbar(mat_id: int) -> void:
    if mat_id <= 0:
        return
    for i in range(_hotbar_materials.size()):
        if int(_hotbar_materials[i]) == mat_id:
            return
    for i in range(_hotbar_materials.size()):
        if int(_hotbar_materials[i]) == 0:
            _hotbar_materials[i] = mat_id
            return

func _material_short_name(material_id: int) -> String:
    match material_id:
        1:
            return "Sand"
        2:
            return "Water"
        3:
            return "Oxy"
        6:
            return "Metal"
        5:
            return "Fire"
        4:
            return "Stone"
        8:
            return "Glass"
        9:
            return "Invis"
        _:
            return "M%d" % material_id

func _snap_player_to_ground(delta: float, instant: bool) -> void:
    if _renderer == null or _player == null:
        return
    var ground_cell := _find_ground_cell_below(_player.global_position)
    if ground_cell.x < 0:
        return
    var grid_extent: int = int(_renderer.chunk_grid) * int(_renderer.chunk_size)
    var spacing: float = float(_renderer.lattice_spacing)
    var ground_world := _cell_to_world(ground_cell, grid_extent, spacing)
    var target_y := ground_world.y + ground_clearance_cells * spacing
    var pos := _player.global_position
    if instant:
        pos.y = target_y
        _player.global_position = pos
        return

    if pos.y < target_y:
        pos.y = target_y
    else:
        var alpha: float = clampf(ground_snap_speed * delta, 0.0, 1.0)
        pos.y = lerpf(pos.y, target_y, alpha)
    _player.global_position = pos

func _find_ground_cell_below(world_pos: Vector3) -> Vector3i:
    if _renderer == null or !_renderer.has_method("get_cell_material"):
        return Vector3i(-1, -1, -1)
    var grid_extent: int = int(_renderer.chunk_grid) * int(_renderer.chunk_size)
    var spacing: float = float(_renderer.lattice_spacing)
    var world_extent: float = float(grid_extent) * spacing
    var origin := Vector3(-0.5 * world_extent, -0.5 * world_extent, -0.5 * world_extent)
    var world_basis := Basis.from_euler(_renderer.world_rotation as Vector3)
    var inv_world := world_basis.transposed()
    var center := origin + Vector3.ONE * (0.5 * world_extent)
    var local_pos := center + inv_world * (world_pos - center)
    var grid_pos := (local_pos - origin) / spacing
    var px := clampi(int(round(grid_pos.x)), 0, grid_extent - 1)
    var pz := clampi(int(round(grid_pos.z)), 0, grid_extent - 1)
    var py := clampi(int(round(grid_pos.y)), 0, grid_extent - 1)

    var best := Vector3i(-1, -1, -1)
    var best_y := -2147483647
    var best_dist2 := 1e20
    var radius := maxi(0, ground_probe_radius_cells)
    for dz in range(-radius, radius + 1):
        for dx in range(-radius, radius + 1):
            var x := clampi(px + dx, 0, grid_extent - 1)
            var z := clampi(pz + dz, 0, grid_extent - 1)
            for y in range(py + 2, -1, -1):
                var raw_cell := Vector3i(x, y, z)
                var cell := _snap_to_bcc(raw_cell, grid_extent)
                if cell.x < 0 or cell.y < 0:
                    continue
                var mat := int(_renderer.get_cell_material(cell))
                if mat == 0:
                    continue
                var d2 := float((cell.x - px) * (cell.x - px) + (cell.z - pz) * (cell.z - pz))
                if cell.y > best_y or (cell.y == best_y and d2 < best_dist2):
                    best = cell
                    best_y = cell.y
                    best_dist2 = d2
                break
    return best
