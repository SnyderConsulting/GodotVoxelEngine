extends Control

@export var camera_path: NodePath
@export var voxel_renderer_path: NodePath
@export var color: Color = Color(1, 1, 1, 0.5)
@export var max_points: int = 400

var _camera: Camera3D
var _renderer: Node
var _cells: Array = []

func _ready() -> void:
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    _camera = get_node_or_null(camera_path) as Camera3D
    _renderer = get_node_or_null(voxel_renderer_path)

func set_cells(cells: Array) -> void:
    _cells = cells
    queue_redraw()

func _draw() -> void:
    if _camera == null or _renderer == null:
        return
    var chunk_grid: int = int(_renderer.chunk_grid)
    var chunk_size: int = int(_renderer.chunk_size)
    var lattice_spacing: float = float(_renderer.lattice_spacing)
    var grid_extent: int = chunk_grid * chunk_size
    var world_extent: float = float(grid_extent) * lattice_spacing
    var origin: Vector3 = Vector3(-0.5 * world_extent, -0.5 * world_extent, -0.5 * world_extent)
    var world_basis: Basis = Basis.from_euler(_renderer.world_rotation)
    var world_center: Vector3 = origin + Vector3.ONE * (0.5 * world_extent)

    var count := 0
    var cam_basis: Basis = _camera.global_transform.basis
    var offset_vec: Vector3 = cam_basis.x * lattice_spacing
    for cell in _cells:
        if count >= max_points:
            break
        if typeof(cell) != TYPE_VECTOR3I:
            continue
        var local_pos: Vector3 = origin + Vector3(cell) * lattice_spacing
        var world_pos: Vector3 = world_center + world_basis * (local_pos - world_center)
        var screen_pos: Vector2 = _camera.unproject_position(world_pos)
        var screen_pos2: Vector2 = _camera.unproject_position(world_pos + offset_vec)
        var radius: float = max(2.0, screen_pos.distance_to(screen_pos2) * 0.4)
        draw_circle(screen_pos, radius, color)
        count += 1
