extends Node
class_name BaseVoxelSceneController

@export var voxel_renderer_path: NodePath
@export var overlay_path: NodePath
@export var hub_scene: String = "res://scenes/ProtoHub.tscn"
@export var random_seed: int = 1337

var renderer: Node = null
var overlay: Label = null
var rng := RandomNumberGenerator.new()
var _init_attempts: int = 0
var _max_init_attempts: int = 120

func _ready() -> void:
    renderer = get_node_or_null(voxel_renderer_path)
    overlay = get_node_or_null(overlay_path) as Label
    if renderer == null:
        push_error("%s missing VoxelRenderer." % name)
        return
    rng.seed = random_seed
    _after_ready()

# Override in subclasses to kick off scene-specific init (e.g., call_deferred(_initialize_scenario))
func _after_ready() -> void:
    pass

func wait_for_renderer_ready(continue_callable: Callable) -> void:
    if renderer == null:
        return
    if renderer.has_method("is_render_ready") and !renderer.is_render_ready():
        _init_attempts += 1
        if _init_attempts <= _max_init_attempts:
            call_deferred(continue_callable)
        else:
            push_error("%s renderer not ready after %d attempts." % [name, _init_attempts])
        return
    _init_attempts = 0
    continue_callable.call()

func _process(_delta: float) -> void:
    if Input.is_action_just_pressed("ui_cancel"):
        get_tree().change_scene_to_file(hub_scene)

func update_overlay_text(text: String) -> void:
    if overlay:
        overlay.text = text

func format_gravity_world(renderer_ref: Node) -> String:
    var gravity = renderer_ref.gravity_dir
    var world_rot = renderer_ref.world_rotation * 180.0 / PI
    return "World Rot deg: (%.1f, %.1f, %.1f)\nGravity: (%.2f, %.2f, %.2f)" % [world_rot.x, world_rot.y, world_rot.z, gravity.x, gravity.y, gravity.z]

func for_each_bcc_cell(renderer_ref: Node, func_ref: Callable) -> void:
    var grid_extent: int = renderer_ref.chunk_grid * renderer_ref.chunk_size
    for z in range(grid_extent):
        for y in range(grid_extent):
            for x in range(grid_extent):
                if !((x & 1) == (y & 1) and (y & 1) == (z & 1)):
                    continue
                func_ref.call(x, y, z, grid_extent)
