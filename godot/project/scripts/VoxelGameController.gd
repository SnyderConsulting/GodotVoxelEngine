extends Node3D

@export var voxel_renderer_path: NodePath
@export var player_path: NodePath
@export var camera_path: NodePath
@export var overlay_path: NodePath
@export var hub_scene: String = "res://scenes/ProtoHub.tscn"

@export var move_speed: float = 18.0
@export var sprint_multiplier: float = 1.8
@export var vertical_speed: float = 14.0
@export var mouse_sensitivity: float = 0.0024
@export var max_reach_world: float = 14.0

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

var _renderer: Node = null
var _player: Node3D = null
var _camera: Camera3D = null
var _overlay: Label = null

var _yaw: float = 0.0
var _pitch: float = 0.0
var _held_material: int = 4
var _init_attempts: int = 0
var _last_scan: Dictionary = {}

func _ready() -> void:
    _renderer = get_node_or_null(voxel_renderer_path)
    _player = get_node_or_null(player_path) as Node3D
    _camera = get_node_or_null(camera_path) as Camera3D
    _overlay = get_node_or_null(overlay_path) as Label
    if _renderer == null or _player == null or _camera == null:
        push_error("VoxelGameController missing required scene references.")
        return
    _held_material = default_place_material
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
        if key_ev.keycode == KEY_1:
            _held_material = default_place_material
        elif key_ev.keycode == KEY_2:
            _held_material = alt_place_material
        elif key_ev.keycode == KEY_3:
            _held_material = fluid_place_material

func _physics_process(delta: float) -> void:
    if _renderer == null or _player == null:
        return
    _update_movement(delta)
    _last_scan = _raycast_from_camera()
    _apply_preview(_last_scan)
    _update_overlay(_last_scan)

func _update_movement(delta: float) -> void:
    var move_x := 0.0
    var move_z := 0.0
    var move_y := 0.0

    if Input.is_physical_key_pressed(KEY_A):
        move_x -= 1.0
    if Input.is_physical_key_pressed(KEY_D):
        move_x += 1.0
    if Input.is_physical_key_pressed(KEY_W):
        move_z -= 1.0
    if Input.is_physical_key_pressed(KEY_S):
        move_z += 1.0
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

    if abs(move_y) > 0.0:
        _player.global_position += Vector3.UP * move_y * vertical_speed * delta

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
    _held_material = mat
    _last_scan = hit
    _apply_preview(hit)
    _update_overlay(hit)

func _place_block() -> void:
    if _renderer == null:
        return
    if _held_material <= 0:
        return
    var hit := _raycast_from_camera()
    var place_cell := hit.get("empty_cell", Vector3i(-1, -1, -1)) as Vector3i
    if place_cell.x < 0:
        return
    if int(_renderer.get_cell_material(place_cell)) != 0:
        return
    _renderer.set_voxel_at(place_cell, _held_material)
    _last_scan = hit
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
    var capture_hint := "Captured" if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED else "Released (left click to capture)"
    var target := "none"
    if bool(hit.get("hit", false)):
        target = _material_name(int(hit.get("material", 0)))
    _overlay.text = (
        "Voxel Game Prototype\n"
        + "WASD move | Shift sprint | Space/Ctrl vertical | Esc release/back\n"
        + "Left click pickup | Right click place | 1 %s | 2 %s | 3 %s\n"
        + "Held: %s  |  Target: %s  |  Mouse: %s"
    ) % [_material_name(default_place_material), _material_name(alt_place_material), _material_name(fluid_place_material), _material_name(_held_material), target, capture_hint]

func _material_name(material_id: int) -> String:
    match material_id:
        1:
            return "Sand (1)"
        2:
            return "Water (2)"
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
