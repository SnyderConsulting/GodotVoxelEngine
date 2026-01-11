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
                if !((x & 1) == (y & 1) and (y & 1) == (z & 1)):
                    continue
                func_ref.call(x, y, z, grid_extent)
