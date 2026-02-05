extends Node

@export var voxel_renderer_path: NodePath
@export var camera_path: NodePath
@export var overlay_path: NodePath
@export var sand_button_path: NodePath
@export var water_button_path: NodePath
@export var brush_slider_path: NodePath
@export var brush_value_path: NodePath
@export var brush_preview_path: NodePath
@export var sand_material_id: int = 1
@export var water_material_id: int = 2
@export var spawn_interval: float = 0.02
@export var brush_radius: int = 1

var _renderer: Node
var _camera: Camera3D
var _overlay: Label
var _sand_button: Button
var _water_button: Button
var _brush_slider: HSlider
var _brush_value: Label
var _brush_preview: Control
var _current_material: int = 1
var _spawn_accum: float = 0.0

func _ready() -> void:
    _renderer = get_node_or_null(voxel_renderer_path)
    _camera = get_node_or_null(camera_path) as Camera3D
    _overlay = get_node_or_null(overlay_path)
    _sand_button = get_node_or_null(sand_button_path)
    _water_button = get_node_or_null(water_button_path)
    _brush_slider = get_node_or_null(brush_slider_path)
    _brush_value = get_node_or_null(brush_value_path)
    _brush_preview = get_node_or_null(brush_preview_path)
    if _sand_button:
        _sand_button.pressed.connect(func() -> void: _set_material(sand_material_id))
    if _water_button:
        _water_button.pressed.connect(func() -> void: _set_material(water_material_id))
    if _brush_slider:
        _brush_slider.value_changed.connect(_on_brush_changed)
        _brush_slider.value = brush_radius
    _set_material(sand_material_id)
    call_deferred("_late_init")
    _update_brush_ui()

func _late_init() -> void:
    if _renderer == null:
        return
    if _renderer.has_method("get") and _renderer.get("_rd") == null:
        call_deferred("_late_init")
        return
    if _renderer.has_method("set_voxel_entries"):
        _renderer.set_voxel_entries([], true)

func _process(delta: float) -> void:
    if _renderer == null or _camera == null:
        return
    var hover := get_viewport().gui_get_hovered_control()
    _update_preview_position()
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
        var name := "Sand" if mat_id == sand_material_id else "Water"
        _overlay.text = "Paint Mode\nMaterial: %s" % name

func _on_brush_changed(value: float) -> void:
    brush_radius = int(round(value))
    _update_brush_ui()

func _update_brush_ui() -> void:
    if _brush_value:
        _brush_value.text = str(brush_radius)
    if _brush_preview:
        _brush_preview.radius_px = 6.0 + float(brush_radius) * 4.0
        _brush_preview.size = Vector2.ONE * (_brush_preview.radius_px * 2.0)

func _spawn_at_cursor() -> void:
    if !_renderer.has_method("set_voxel_at"):
        return
    var cell: Vector3i = _raycast_to_cell()
    if cell.x < 0:
        return
    _spawn_brush(cell)

func _spawn_brush(center: Vector3i) -> void:
    var r: int = int(max(0, brush_radius))
    if r == 0:
        _renderer.set_voxel_at(center, _current_material)
        return
    var r2: int = r * r
    for dz in range(-r, r + 1):
        for dy in range(-r, r + 1):
            for dx in range(-r, r + 1):
                if dx * dx + dy * dy + dz * dz > r2:
                    continue
                var cell: Vector3i = center + Vector3i(dx, dy, dz)
                _renderer.set_voxel_at(cell, _current_material)

func _raycast_to_cell() -> Vector3i:
    var mouse_pos: Vector2 = get_viewport().get_mouse_position()
    var ro: Vector3 = _camera.project_ray_origin(mouse_pos)
    var rd: Vector3 = _camera.project_ray_normal(mouse_pos)

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
    var t: float = _ray_aabb(ro_local, rd_local, box_min, box_max)
    if t >= 1e19:
        return Vector3i(-1, -1, -1)
    if t < 0.0:
        t = 0.0
    var p: Vector3 = ro_local + rd_local * (t + lattice_spacing * 0.5)
    var grid_pos: Vector3 = (p - origin) / lattice_spacing
    var cell: Vector3i = _nearest_bcc(grid_pos)
    if cell.x < 0 or cell.y < 0 or cell.z < 0 or cell.x >= grid_extent or cell.y >= grid_extent or cell.z >= grid_extent:
        return Vector3i(-1, -1, -1)
    return cell

func _ray_aabb(ro: Vector3, rd: Vector3, bmin: Vector3, bmax: Vector3) -> float:
    var tmin: float = -1e9
    var tmax: float = 1e9
    for axis in [0, 1, 2]:
        var o: float = ro[axis]
        var d: float = rd[axis]
        var minv: float = bmin[axis]
        var maxv: float = bmax[axis]
        if abs(d) < 1e-6:
            if o < minv or o > maxv:
                return 1e20
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
                return 1e20
    return tmin

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

func _update_preview_position() -> void:
    if _brush_preview == null:
        return
    var cell: Vector3i = _raycast_to_cell()
    if cell.x < 0:
        _brush_preview.visible = false
        return
    _brush_preview.visible = true
    var world_pos: Vector3 = _cell_to_world(cell)
    var screen_pos: Vector2 = _camera.unproject_position(world_pos)
    _brush_preview.position = screen_pos - Vector2.ONE * _brush_preview.radius_px

func _cell_to_world(cell: Vector3i) -> Vector3:
    var chunk_grid: int = int(_renderer.chunk_grid)
    var chunk_size: int = int(_renderer.chunk_size)
    var lattice_spacing: float = float(_renderer.lattice_spacing)
    var grid_extent: int = chunk_grid * chunk_size
    var world_extent: float = float(grid_extent) * lattice_spacing
    var origin: Vector3 = Vector3(-0.5 * world_extent, -0.5 * world_extent, -0.5 * world_extent)
    var world_basis: Basis = Basis.from_euler(_renderer.world_rotation)
    var world_center: Vector3 = origin + Vector3.ONE * (0.5 * world_extent)
    var local_pos: Vector3 = origin + Vector3(cell) * lattice_spacing
    return world_center + world_basis * (local_pos - world_center)
