extends Node

@export var voxel_renderer_path: NodePath
@export var camera_path: NodePath
@export var quad_path: NodePath
@export var overlay_path: NodePath
@export var sand_button_path: NodePath
@export var water_button_path: NodePath
@export var material_dropdown_path: NodePath
@export var brush_slider_path: NodePath
@export var brush_value_path: NodePath
@export var sand_material_id: int = 1
@export var water_material_id: int = 2
@export var materials_json_path: String = "res://data/materials.json"
@export var hub_scene: String = "res://scenes/ProtoHub.tscn"
@export var spawn_interval: float = 0.02
@export var brush_radius: int = 1
@export var max_voxels_per_spawn: int = 256
@export var debug_logging: bool = false
@export var debug_log_every: int = 60

var _renderer: Node
var _camera: Camera3D
var _quad: MeshInstance3D
var _overlay: Label
var _sand_button: Button
var _water_button: Button
var _material_dropdown: OptionButton
var _brush_slider: HSlider
var _brush_value: Label
var _current_material: int = 1
var _material_name_by_id: Dictionary = {}
var _spawn_accum: float = 0.0
var _last_center := Vector3i(-1, -1, -1)
var _last_brush_cells: Array = []
var _last_mouse_pos: Vector2 = Vector2.ZERO
var _last_mouse_valid: bool = false
var _debug_frame: int = 0
var _debug_quad_min: Vector2 = Vector2.ZERO
var _debug_quad_max: Vector2 = Vector2.ZERO
var _debug_uv: Vector2 = Vector2(-1, -1)
var _cap_hit: bool = false

func _ready() -> void:
    _renderer = get_node_or_null(voxel_renderer_path)
    _camera = get_node_or_null(camera_path) as Camera3D
    _quad = get_node_or_null(quad_path) as MeshInstance3D
    _overlay = get_node_or_null(overlay_path)
    _sand_button = get_node_or_null(sand_button_path)
    _water_button = get_node_or_null(water_button_path)
    _material_dropdown = get_node_or_null(material_dropdown_path) as OptionButton
    _brush_slider = get_node_or_null(brush_slider_path)
    _brush_value = get_node_or_null(brush_value_path)
    if _sand_button:
        _sand_button.pressed.connect(func() -> void: _set_material(sand_material_id))
    if _water_button:
        _water_button.pressed.connect(func() -> void: _set_material(water_material_id))
    _load_material_list()
    _setup_material_dropdown()
    if _brush_slider:
        _brush_slider.value_changed.connect(_on_brush_changed)
        _brush_slider.value = brush_radius
    _set_material(sand_material_id)
    call_deferred("_late_init")
    _update_brush_ui()

func _load_material_list() -> void:
    _material_name_by_id.clear()
    if materials_json_path.is_empty() or !FileAccess.file_exists(materials_json_path):
        _material_name_by_id[sand_material_id] = "sand"
        _material_name_by_id[water_material_id] = "water"
        return
    var text := FileAccess.get_file_as_string(materials_json_path)
    var parsed: Variant = JSON.parse_string(text)
    if typeof(parsed) != TYPE_DICTIONARY:
        _material_name_by_id[sand_material_id] = "sand"
        _material_name_by_id[water_material_id] = "water"
        return
    var mats: Array = (parsed as Dictionary).get("materials", [])
    if typeof(mats) != TYPE_ARRAY:
        _material_name_by_id[sand_material_id] = "sand"
        _material_name_by_id[water_material_id] = "water"
        return
    for m in mats:
        if typeof(m) != TYPE_DICTIONARY:
            continue
        var id := int((m as Dictionary).get("id", -1))
        if id <= 0:
            continue
        var name := str((m as Dictionary).get("name", "mat_%d" % id))
        _material_name_by_id[id] = name

func _setup_material_dropdown() -> void:
    if _material_dropdown == null:
        return
    _material_dropdown.clear()
    var ids: Array = _material_name_by_id.keys()
    ids.sort()
    for idv in ids:
        var mid := int(idv)
        var name := str(_material_name_by_id.get(mid, "mat_%d" % mid))
        # Glass/invisible are static obstacles in the MPM path.
        if mid == 8:
            name = "%s (static)" % name
        elif mid == 9:
            name = "%s (static)" % name
        _material_dropdown.add_item("%s [%d]" % [name, mid], mid)
    _material_dropdown.item_selected.connect(_on_material_dropdown_selected)
    # Select current material if present.
    for i in range(_material_dropdown.item_count):
        if _material_dropdown.get_item_id(i) == _current_material:
            _material_dropdown.select(i)
            return

func _on_material_dropdown_selected(index: int) -> void:
    if _material_dropdown == null:
        return
    var mat_id := int(_material_dropdown.get_item_id(index))
    if mat_id > 0:
        _set_material(mat_id)

func _late_init() -> void:
    if _renderer == null:
        return
    if _renderer.has_method("get") and _renderer.get("_rd") == null:
        call_deferred("_late_init")
        return
    _renderer.sim_mode = 1
    if _renderer.has_method("set_voxel_entries_mpm"):
        _renderer.set_voxel_entries_mpm([])
    elif _renderer.has_method("set_voxel_entries"):
        _renderer.set_voxel_entries([], true)

func _process(delta: float) -> void:
    if Input.is_action_just_pressed("ui_cancel"):
        get_tree().change_scene_to_file(hub_scene)
        return
    if _renderer == null or _camera == null:
        return
    _debug_frame += 1
    if debug_logging and (debug_log_every > 0) and (_debug_frame % debug_log_every == 0):
        print("PaintController tick | frame=%d mouse_raw=%s mouse_vp=%s" % [
            _debug_frame,
            str(_last_mouse_pos),
            str(_get_mouse_viewport_pos())
        ])
    var hover := get_viewport().gui_get_hovered_control()
    _update_preview()
    if hover != null:
        _spawn_accum = 0.0
        return
    if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
        _spawn_accum += delta
        while _spawn_accum >= spawn_interval:
            _spawn_accum -= spawn_interval
            _spawn_at_cursor()
    else:
        _spawn_accum = 0.0

func _set_material(mat_id: int) -> void:
    _current_material = mat_id
    if _overlay:
        var name := str(_material_name_by_id.get(mat_id, "mat_%d" % mat_id))
        var cap_line := "\nCAP HIT (increase mpm_max_particles)" if _cap_hit else ""
        _overlay.text = "Paint Mode\nMaterial: %s%s\nEsc: hub" % [name, cap_line]
    if _material_dropdown != null:
        for i in range(_material_dropdown.item_count):
            if _material_dropdown.get_item_id(i) == mat_id:
                _material_dropdown.select(i)
                break

func _on_brush_changed(value: float) -> void:
    brush_radius = int(round(value))
    _update_brush_ui()

func _update_brush_ui() -> void:
    if _brush_value:
        _brush_value.text = str(brush_radius)
    # preview handled via VoxelRenderer buffer

func _spawn_at_cursor() -> void:
    var cell: Vector3i = _raycast_to_cell()
    if cell.x < 0:
        return
    var cells := _get_brush_cells(cell)
    _spawn_cells(cells)

func _spawn_cells(cells: Array) -> void:
    if _renderer == null:
        return
    var batch: Array = []
    var count := 0
    for cell in cells:
        if max_voxels_per_spawn > 0 and count >= max_voxels_per_spawn:
            break
        if typeof(cell) != TYPE_VECTOR3I:
            continue
        batch.append(cell)
        count += 1
    if batch.size() == 0:
        return
    # Some materials are meant to be static obstacles (not MPM particles).
    if _current_material == 8 or _current_material == 9:
        _cap_hit = false
        if _renderer.has_method("set_voxel_at"):
            for cell in batch:
                _renderer.set_voxel_at(cell, _current_material)
        _set_material(_current_material)
        return
    if _renderer.has_method("mpm_spawn_cells"):
        # Spawn voxel-sized particles (BCC Voronoi volume ~= 4 in grid space).
        var spawned := int(_renderer.mpm_spawn_cells(batch, _current_material, Vector3.ZERO, 4.0))
        _cap_hit = spawned < batch.size()
        if _cap_hit and debug_logging:
            print("PaintController | particle cap hit (requested=%d spawned=%d)" % [batch.size(), spawned])
        # Refresh overlay so the cap warning shows even if material didn't change.
        _set_material(_current_material)
        return
    if _renderer.has_method("set_voxel_at"):
        for cell in batch:
            _renderer.set_voxel_at(cell, _current_material)

func _raycast_to_cell() -> Vector3i:
    var mouse_pos: Vector2 = _get_mouse_viewport_pos()
    var ray: Dictionary = _mouse_ray_from_viewport(mouse_pos)
    if ray.is_empty():
        if debug_logging and (debug_log_every > 0) and (_debug_frame % debug_log_every == 0):
            print("PaintController debug | frame=%d mouse=%s ray=empty quad_min=%s quad_max=%s uv=%s renderer_wh=(%d,%d) viewport=%s world_rot=%s" % [
                _debug_frame,
                str(mouse_pos),
                str(_debug_quad_min),
                str(_debug_quad_max),
                str(_debug_uv),
                int(_renderer.width),
                int(_renderer.height),
                str(get_viewport().get_visible_rect().size),
                str(_renderer.world_rotation)
            ])
        return Vector3i(-1, -1, -1)
    var ro: Vector3 = ray["ro"]
    var rd: Vector3 = ray["rd"]

    var chunk_grid: int = int(_renderer.chunk_grid)
    var chunk_size: int = int(_renderer.chunk_size)
    var lattice_spacing: float = float(_renderer.lattice_spacing)
    var grid_extent: int = chunk_grid * chunk_size
    var world_extent: float = float(grid_extent) * lattice_spacing
    var origin: Vector3 = Vector3(-0.5 * world_extent, -0.5 * world_extent, -0.5 * world_extent)
    var world_basis: Basis = Basis.from_euler(_renderer.world_rotation)
    var inv_world: Basis = world_basis.transposed()
    var world_center: Vector3 = origin + Vector3.ONE * (0.5 * world_extent)

    var ro_local: Vector3 = world_center + inv_world * (ro - world_center)
    var rd_local: Vector3 = (inv_world * rd).normalized()

    var box_min: Vector3 = origin
    var box_max: Vector3 = origin + Vector3.ONE * world_extent
    var range: Vector2 = _ray_aabb_range(ro_local, rd_local, box_min, box_max)
    if range.x >= 1e19:
        if debug_logging and (debug_log_every > 0) and (_debug_frame % debug_log_every == 0):
            print("PaintController debug | frame=%d miss_aabb ro_local=%s rd_local=%s box_min=%s box_max=%s" % [
                _debug_frame,
                str(ro_local),
                str(rd_local),
                str(box_min),
                str(box_max)
            ])
        return Vector3i(-1, -1, -1)
    var tmin: float = range.x
    var tmax: float = range.y
    var t_center: float = (world_center - ro_local).dot(rd_local)
    var t: float = clamp(t_center, tmin, tmax)
    var hit_cell: Vector3i = _raycast_voxel_hit(ro_local, rd_local, origin, lattice_spacing, grid_extent, tmin, tmax)
    if hit_cell.x < 0:
        if debug_logging and (debug_log_every > 0) and (_debug_frame % debug_log_every == 0):
            print("PaintController debug | frame=%d miss_grid tmin=%.3f tmax=%.3f ro_local=%s rd_local=%s" % [
                _debug_frame,
                tmin,
                tmax,
                str(ro_local),
                str(rd_local)
            ])
        return Vector3i(-1, -1, -1)
    if debug_logging and (debug_log_every > 0) and (_debug_frame % debug_log_every == 0):
        print("PaintController debug | frame=%d mouse=%s ro=%s rd=%s cell=%s" % [
            _debug_frame,
            str(mouse_pos),
            str(ro),
            str(rd),
            str(hit_cell)
        ])
        print("PaintController debug | frame=%d quad_min=%s quad_max=%s uv=%s renderer_wh=(%d,%d) viewport=%s world_rot=%s" % [
            _debug_frame,
            str(_debug_quad_min),
            str(_debug_quad_max),
            str(_debug_uv),
            int(_renderer.width),
            int(_renderer.height),
            str(get_viewport().get_visible_rect().size),
            str(_renderer.world_rotation)
        ])
    return hit_cell

func _mouse_ray_from_viewport(mouse_pos: Vector2) -> Dictionary:
    if _camera == null:
        return {}
    var uv := _mouse_uv_on_quad(mouse_pos)
    if uv.x < 0.0:
        return {}
    var ndc: Vector2 = uv * 2.0 - Vector2.ONE
    ndc.y = -ndc.y
    var fov: float = deg_to_rad(_camera.fov)
    var tan_half_fov: float = tan(fov * 0.5)
    var aspect: float = float(_renderer.width) / float(_renderer.height)
    var basis: Basis = _camera.global_transform.basis
    var ro: Vector3 = _camera.global_transform.origin
    var rd_world: Vector3 = (basis.z * -1.0 + basis.x * (ndc.x * aspect * tan_half_fov) + basis.y * (ndc.y * tan_half_fov)).normalized()
    return {"ro": ro, "rd": rd_world}

func _mouse_uv_on_quad(mouse_pos: Vector2) -> Vector2:
    if _quad == null or _camera == null:
        return Vector2(-1.0, -1.0)
    # Project quad corners into screen space and derive UV in that rectangle.
    var quad_tf: Transform3D = _quad.global_transform
    var quad_mesh := _quad.mesh as QuadMesh
    var size: Vector2 = quad_mesh.size if quad_mesh != null else Vector2(2, 2)
    var half := size * 0.5
    var corners_local := [
        Vector3(-half.x, -half.y, 0.0),
        Vector3(half.x, -half.y, 0.0),
        Vector3(half.x, half.y, 0.0),
        Vector3(-half.x, half.y, 0.0)
    ]
    var min_xy := Vector2(1e9, 1e9)
    var max_xy := Vector2(-1e9, -1e9)
    for c in corners_local:
        var world: Vector3 = quad_tf * c
        var screen: Vector2 = _camera.unproject_position(world)
        min_xy = Vector2(min(min_xy.x, screen.x), min(min_xy.y, screen.y))
        max_xy = Vector2(max(max_xy.x, screen.x), max(max_xy.y, screen.y))
    var size_xy := max_xy - min_xy
    if size_xy.x <= 1.0 or size_xy.y <= 1.0:
        _debug_quad_min = min_xy
        _debug_quad_max = max_xy
        _debug_uv = Vector2(-1, -1)
        return Vector2(-1.0, -1.0)
    var uv := (mouse_pos - min_xy) / size_xy
    if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
        _debug_quad_min = min_xy
        _debug_quad_max = max_xy
        _debug_uv = uv
        return Vector2(-1.0, -1.0)
    _debug_quad_min = min_xy
    _debug_quad_max = max_xy
    _debug_uv = uv
    return uv

func _input(event: InputEvent) -> void:
    if event is InputEventMouseMotion:
        _record_mouse(event.position)
    elif event is InputEventMouseButton:
        _record_mouse(event.position)

func _record_mouse(pos: Vector2) -> void:
    _last_mouse_pos = pos
    _last_mouse_valid = true

func _get_mouse_viewport_pos() -> Vector2:
    if _last_mouse_valid:
        return _last_mouse_pos
    return get_viewport().get_mouse_position()

func _ray_aabb_range(ro: Vector3, rd: Vector3, bmin: Vector3, bmax: Vector3) -> Vector2:
    var tmin: float = -1e9
    var tmax: float = 1e9
    for axis in [0, 1, 2]:
        var o: float = ro[axis]
        var d: float = rd[axis]
        var minv: float = bmin[axis]
        var maxv: float = bmax[axis]
        if abs(d) < 1e-6:
            if o < minv or o > maxv:
                return Vector2(1e20, 1e20)
        else:
            var inv: float = 1.0 / d
            var t1: float = (minv - o) * inv
            var t2: float = (maxv - o) * inv
            if t1 > t2:
                var tmp: float = t1
                t1 = t2
                t2 = tmp
            tmin = max(tmin, t1)
            tmax = min(tmax, t2)
            if tmin > tmax:
                return Vector2(1e20, 1e20)
    return Vector2(tmin, tmax)

func _raycast_voxel_hit(ro_local: Vector3, rd_local: Vector3, origin: Vector3, spacing: float, grid_extent: int, tmin: float, tmax: float) -> Vector3i:
    if !_renderer.has_method("get_cell_material"):
        # fallback to center if we can't query the atlas
        var t: float = clamp(0.5 * (tmin + tmax), tmin, tmax)
        var p: Vector3 = ro_local + rd_local * (t + spacing * 0.5)
        var grid_pos: Vector3 = (p - origin) / spacing
        var cell: Vector3i = _nearest_bcc(grid_pos)
        return cell
    var t: float = max(tmin, 0.0) + 1e-4
    var p: Vector3 = ro_local + rd_local * t
    var grid_pos: Vector3 = (p - origin) / spacing
    var cell: Vector3i = Vector3i(floor(grid_pos.x), floor(grid_pos.y), floor(grid_pos.z))
    var step: Vector3i = Vector3i(sign(rd_local.x), sign(rd_local.y), sign(rd_local.z))
    var next_boundary := Vector3(
        cell.x + (1 if step.x > 0 else 0),
        cell.y + (1 if step.y > 0 else 0),
        cell.z + (1 if step.z > 0 else 0)
    )
    var dx: float = rd_local.x
    var dy: float = rd_local.y
    var dz: float = rd_local.z
    var dx_safe := dx if abs(dx) > 1e-6 else 1e-6
    var dy_safe := dy if abs(dy) > 1e-6 else 1e-6
    var dz_safe := dz if abs(dz) > 1e-6 else 1e-6
    var t_max: Vector3 = Vector3(
        (next_boundary.x - grid_pos.x) / dx_safe,
        (next_boundary.y - grid_pos.y) / dy_safe,
        (next_boundary.z - grid_pos.z) / dz_safe
    )
    var t_delta: Vector3 = Vector3(
        1.0 / abs(dx_safe),
        1.0 / abs(dy_safe),
        1.0 / abs(dz_safe)
    )
    var last_empty: Vector3i = Vector3i(-1, -1, -1)
    while t <= tmax:
        if cell.x < 0 or cell.y < 0 or cell.z < 0 or cell.x >= grid_extent or cell.y >= grid_extent or cell.z >= grid_extent:
            break
        var mat: int = _renderer.get_cell_material(cell)
        if mat != 0:
            # place on the last empty cell before hit if available
            if last_empty.x >= 0:
                return last_empty
            return cell
        last_empty = cell
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
    # no hit: return last empty if any
    if last_empty.x >= 0:
        return last_empty
    if debug_logging and (debug_log_every > 0) and (_debug_frame % debug_log_every == 0):
        print("PaintController debug | frame=%d last_empty=-1 grid_pos=%s cell=%s grid_extent=%d origin=%s spacing=%.3f t=%.3f tmax=%.3f" % [
            _debug_frame,
            str(grid_pos),
            str(cell),
            grid_extent,
            str(origin),
            spacing,
            t,
            tmax
        ])
    return Vector3i(-1, -1, -1)

func _nearest_bcc(pos: Vector3) -> Vector3i:
    var base: Vector3i = Vector3i(floor(pos.x), floor(pos.y), floor(pos.z))
    var best: Vector3i = base
    var best_dist: float = 1e9
    for dz in range(2):
        for dy in range(2):
            for dx in range(2):
                var cand: Vector3i = base + Vector3i(dx, dy, dz)
                if ((cand.x & 1) != (cand.y & 1)) or ((cand.y & 1) != (cand.z & 1)):
                    continue
                var dist: float = (pos - Vector3(cand)).length()
                if dist < best_dist:
                    best_dist = dist
                    best = cand
    return best

func _update_preview() -> void:
    if _renderer == null:
        return
    var cell: Vector3i = _raycast_to_cell()
    if debug_logging and (debug_log_every > 0) and (_debug_frame % debug_log_every == 0):
        print("PaintController preview | frame=%d cell=%s" % [_debug_frame, str(cell)])
    if cell.x < 0:
        _last_center = Vector3i(-1, -1, -1)
        _last_brush_cells = []
        if _renderer.has_method("set_preview_cells"):
            _renderer.set_preview_cells([])
        if _renderer.has_method("set_cursor_cell"):
            _renderer.set_cursor_cell(Vector3i(-1, -1, -1))
        return
    if _renderer.has_method("set_cursor_cell"):
        _renderer.set_cursor_cell(cell)
    var cells := _get_brush_cells(cell)
    if _renderer.has_method("set_preview_cells"):
        _renderer.set_preview_cells(cells)

func _get_brush_cells(center: Vector3i) -> Array:
    if center == _last_center and _last_brush_cells.size() > 0:
        return _last_brush_cells
    var r: int = int(max(0, brush_radius))
    var out: Array = []
    var seen := {}
    if r == 0:
        var snapped := _snap_to_bcc(center)
        if snapped.x >= 0:
            out.append(snapped)
    else:
        var r2: int = r * r
        for dz in range(-r, r + 1):
            for dy in range(-r, r + 1):
                for dx in range(-r, r + 1):
                    if dx * dx + dy * dy + dz * dz > r2:
                        continue
                    var cell := center + Vector3i(dx, dy, dz)
                    var snapped := _snap_to_bcc(cell)
                    if snapped.x < 0:
                        continue
                    var key := str(snapped)
                    if seen.has(key):
                        continue
                    seen[key] = true
                    out.append(snapped)
    _last_center = center
    _last_brush_cells = out
    return out

func _snap_to_bcc(cell: Vector3i) -> Vector3i:
    var chunk_grid: int = int(_renderer.chunk_grid)
    var chunk_size: int = int(_renderer.chunk_size)
    var grid_extent: int = chunk_grid * chunk_size
    var cand: Vector3i = _nearest_bcc(Vector3(cell))
    if cand.x < 0 or cand.y < 0 or cand.z < 0 or cand.x >= grid_extent or cand.y >= grid_extent or cand.z >= grid_extent:
        return Vector3i(-1, -1, -1)
    return cand
