extends Node
class_name BaseVoxelShared

var renderer: Node = null
var overlay: Label = null
var rng := RandomNumberGenerator.new()
var _init_attempts: int = 0
var _max_init_attempts: int = 120

func bind(renderer_path: NodePath, overlay_path: NodePath, random_seed: int) -> void:
    renderer = get_node_or_null(renderer_path)
    overlay = get_node_or_null(overlay_path) as Label
    if renderer == null:
        push_error("%s missing VoxelRenderer." % name)
        return
    rng.seed = random_seed

func wait_for_renderer_ready(continue_callable: Callable) -> void:
    if renderer == null:
        return
    if renderer.has_method("is_render_ready") and !renderer.is_render_ready():
        _init_attempts += 1
        if _init_attempts <= _max_init_attempts:
            call_deferred("wait_for_renderer_ready", continue_callable)
        else:
            push_error("%s renderer not ready after %d attempts." % [name, _init_attempts])
        return
    _init_attempts = 0
    continue_callable.call()

func begin_scene_build(target_sim_mode: int = 1) -> void:
    if renderer == null:
        return
    # Avoid a few frames of simulation against an empty/uninitialized scenario.
    renderer.sim_enabled = false
    renderer.sim_mode = target_sim_mode

func end_scene_build(enable_sim: bool = true) -> void:
    if renderer == null:
        return
    renderer.sim_enabled = enable_sim

func apply_entries(entries: Array, allocate_all_bricks: bool = true) -> void:
    if renderer == null:
        return
    if renderer.has_method("set_voxel_entries_mpm"):
        renderer.set_voxel_entries_mpm(entries)
        return
    renderer.set_voxel_entries(entries, allocate_all_bricks)

func is_bcc_cell(x: int, y: int, z: int) -> bool:
    return ((x & 1) == (y & 1)) and ((y & 1) == (z & 1))

func snap_to_bcc(cell: Vector3i, grid_extent: int) -> Vector3i:
    if cell.x < 0 or cell.y < 0 or cell.z < 0 or cell.x >= grid_extent or cell.y >= grid_extent or cell.z >= grid_extent:
        return Vector3i(-1, -1, -1)
    if is_bcc_cell(cell.x, cell.y, cell.z):
        return cell
    var y1 := cell.y - 1
    if y1 >= 0 and is_bcc_cell(cell.x, y1, cell.z):
        return Vector3i(cell.x, y1, cell.z)
    var y2 := cell.y + 1
    if y2 < grid_extent and is_bcc_cell(cell.x, y2, cell.z):
        return Vector3i(cell.x, y2, cell.z)
    var x2 := cell.x + 1
    if x2 < grid_extent and is_bcc_cell(x2, cell.y, cell.z):
        return Vector3i(x2, cell.y, cell.z)
    var x1 := cell.x - 1
    if x1 >= 0 and is_bcc_cell(x1, cell.y, cell.z):
        return Vector3i(x1, cell.y, cell.z)
    return Vector3i(-1, -1, -1)

func update_overlay_text(text: String) -> void:
    if overlay:
        overlay.text = text

func format_gravity_world(renderer_ref: Node) -> String:
    var gravity = renderer_ref.gravity_dir
    var world_rot = renderer_ref.world_rotation * 180.0 / PI
    return "World Rot deg: (%.1f, %.1f, %.1f)\nGravity: (%.2f, %.2f, %.2f)" % [
        world_rot.x, world_rot.y, world_rot.z, gravity.x, gravity.y, gravity.z]

func compose_overlay(
        title: String,
        description: String,
        renderer_ref: Node,
        include_sliders: bool = true,
        include_escape_hint: bool = false,
        include_gravity: bool = true) -> String:
    var lines := []
    if title != "":
        lines.append(title)
    if include_sliders:
        lines.append("Use the sliders for gravity and world rotation.")
    if description != "":
        lines.append(description)
    if include_escape_hint:
        lines.append("Esc: hub")
    if include_gravity and renderer_ref != null:
        lines.append(format_gravity_world(renderer_ref))
    return "\n".join(lines)

func for_each_bcc_cell(renderer_ref: Node, func_ref: Callable) -> void:
    var grid_extent: int = renderer_ref.chunk_grid * renderer_ref.chunk_size
    for z in range(grid_extent):
        for y in range(grid_extent):
            for x in range(grid_extent):
                if !is_bcc_cell(x, y, z):
                    continue
                func_ref.call(x, y, z, grid_extent)
