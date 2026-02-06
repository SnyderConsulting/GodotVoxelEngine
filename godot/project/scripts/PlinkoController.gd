extends Node

@export var voxel_renderer_path: NodePath
@export var overlay_path: NodePath
@export var spawn_button_path: NodePath
@export var sand_material_id: int = 1
@export var glass_material_id: int = 8
@export var invisible_material_id: int = 9
@export var hub_scene: String = "res://scenes/ProtoHub.tscn"
@export var floor_thickness: int = 2
@export var board_margin: int = 4
@export var board_thickness: int = 2
@export var peg_spacing: int = 5
@export var peg_rows: int = 16
@export var peg_row_trim_top: int = 2
@export var peg_row_trim_bottom: int = 2
@export var wall_thickness: int = 2
@export var max_spawn: int = 200

var _renderer: Node
var _overlay: Label
var _spawn_button: Button
var _entries: Array = []
var _grid_extent: int = 0
var _center: int = 0
var _spawned: int = 0
var _spawn_y: int = 0

func _ready() -> void:
    _renderer = get_node_or_null(voxel_renderer_path)
    if _renderer == null:
        push_error("PlinkoController: missing VoxelRenderer")
        return
    _overlay = get_node_or_null(overlay_path)
    if _overlay:
        _overlay.text = "Plinko Board\nSpawned: 0\nEsc: hub"
    _spawn_button = get_node_or_null(spawn_button_path)
    if _spawn_button:
        _spawn_button.pressed.connect(_on_spawn_pressed)

    _grid_extent = int(_renderer.chunk_grid * _renderer.chunk_size)
    _center = int((_grid_extent - 1) * 0.5)
    _spawn_y = _compute_spawn_y(_center, _center)

    call_deferred("_late_init")

func _late_init() -> void:
    if _renderer != null and _renderer.has_method("get") and _renderer.get("_rd") == null:
        call_deferred("_late_init")
        return
    if _renderer != null:
        _renderer.sim_mode = 1
    _build_board()
    _apply_entries()

    # Debug bridge: probe the spawn cell so we can observe atlas/state.
    if _renderer != null:
        _renderer.debug_probe_enabled = true
        _renderer.debug_probe_every = 30
        _renderer.set_debug_probe_cell_xyz(_center, _spawn_y, _center)

    # Auto-spawn one sand voxel for debug visibility.
    _spawn_sand()

func _process(_delta: float) -> void:
    if Input.is_action_just_pressed("ui_cancel"):
        get_tree().change_scene_to_file(hub_scene)
        return

func _on_spawn_pressed() -> void:
    _spawn_sand()

func _spawn_sand() -> void:
    if _spawned >= max_spawn:
        return
    _spawned += 1
    var pos := Vector3i(_center, _spawn_y, _center)
    if _renderer != null and _renderer.has_method("set_voxel_at"):
        _renderer.set_voxel_at(pos, sand_material_id)
    else:
        var entry := {"pos": Vector3(pos.x, pos.y, pos.z), "material": sand_material_id}
        _entries.append(entry)
        _apply_entries()
    if _overlay:
        _overlay.text = "Plinko Board\nSpawned: %d" % _spawned
    print("Plinko spawn | count=%d pos=%s" % [_spawned, str(pos)])

func _build_board() -> void:
    _entries.clear()
    var board_min: int = int(clamp(board_margin, 0, _grid_extent - 1))
    var board_max: int = int(clamp(_grid_extent - 1 - board_margin, 0, _grid_extent - 1))
    var z_min: int = int(clamp(_center - board_thickness, 0, _grid_extent - 1))
    var z_max: int = int(clamp(_center + board_thickness, 0, _grid_extent - 1))

    # Invisible container: use invisible material for walls/floor, glass for pegs.
    var wt: int = int(max(1, wall_thickness))

    # Floor (thick, no gaps).
    for y in range(floor_thickness):
        for z in range(z_min, z_max + 1):
            for x in range(board_min, board_max + 1):
                _append_if_parity(x, y, z, invisible_material_id)

    # Side walls (thick).
    for y in range(floor_thickness, _grid_extent):
        for z in range(z_min, z_max + 1):
            for t in range(wt):
                var xl := board_min + t
                var xr := board_max - t
                if xl <= xr:
                    _append_if_parity(xl, y, z, invisible_material_id)
                    _append_if_parity(xr, y, z, invisible_material_id)

    # Front/back walls to keep the board narrow in Z (thick).
    for y in range(floor_thickness, _grid_extent):
        for x in range(board_min, board_max + 1):
            for t in range(wt):
                var zl := z_min + t
                var zr := z_max - t
                if zl <= zr:
                    _append_if_parity(x, y, zl, invisible_material_id)
                    _append_if_parity(x, y, zr, invisible_material_id)

    # Pegs (glass bounce poles) only.
    var base_y: int = _grid_extent - 4
    for row in range(peg_rows):
        if row < peg_row_trim_top or row >= peg_rows - peg_row_trim_bottom:
            continue
        var y: int = base_y - row * peg_spacing
        if y <= 1:
            break
        var offset: int = 0
        if (row % 2) == 1:
            offset = int(peg_spacing / 2)
        var x: int = board_min + 2 + offset
        while x < board_max - 1:
            for z in range(z_min + 1, z_max):
                _append_if_parity(x, y, z, glass_material_id)
            x += peg_spacing

func _append_if_parity(x: int, y: int, z: int, mat_id: int) -> void:
    if x < 0 or y < 0 or z < 0 or x >= _grid_extent or y >= _grid_extent or z >= _grid_extent:
        return
    if ((x & 1) == (y & 1)) and ((y & 1) == (z & 1)):
        _entries.append({"pos": Vector3(x, y, z), "material": mat_id})
        return
    var y2 := y - 1
    if y2 >= 0 and ((x & 1) == (y2 & 1)) and ((y2 & 1) == (z & 1)):
        _entries.append({"pos": Vector3(x, y2, z), "material": mat_id})
        return
    y2 = y + 1
    if y2 < _grid_extent and ((x & 1) == (y2 & 1)) and ((y2 & 1) == (z & 1)):
        _entries.append({"pos": Vector3(x, y2, z), "material": mat_id})

func _apply_entries() -> void:
    if _renderer == null:
        return
    if _entries.size() > 0:
        var last_entry = _entries[_entries.size() - 1]
        print("Plinko apply | entries=%d last=%s" % [_entries.size(), str(last_entry)])
    if _renderer.has_method("set_voxel_entries_mpm"):
        _renderer.set_voxel_entries_mpm(_entries)
    else:
        _renderer.set_voxel_entries(_entries, true)

func _compute_spawn_y(x: int, z: int) -> int:
    var y := _grid_extent - 2
    if ((x & 1) != (y & 1)) or ((y & 1) != (z & 1)):
        y -= 1
    return y

func _schedule_scan(delay: float) -> void:
    if _renderer == null:
        return
    var timer := get_tree().create_timer(delay)
    if timer == null:
        return
    timer.timeout.connect(func() -> void:
        if _renderer != null:
            _renderer.debug_scan_for_material(sand_material_id, 300000)
    )
