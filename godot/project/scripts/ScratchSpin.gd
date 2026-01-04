extends Node3D

const GRID_SIZE := 128
const BRICK_SIZE := 8
const BRICK_COUNT := GRID_SIZE / BRICK_SIZE

@export var spin_speed := 0.8
@export var debug_mode := 0
@export var raymarch_camera_path: NodePath = NodePath("OrbitCamera/Camera3D")
@export var raymarch_quad_path: NodePath = NodePath("OrbitCamera/Camera3D/RaymarchQuad")
@export var orbit_rig_path: NodePath = NodePath("OrbitCamera")
@export var raymarch_target := Vector3.ZERO
@export var log_every_frame := true
@export var log_path := "user://render_log.txt"

@onready var _box: MeshInstance3D = $Box
@onready var _camera: Camera3D = get_node(raymarch_camera_path) as Camera3D
@onready var _quad: MeshInstance3D = get_node(raymarch_quad_path) as MeshInstance3D
@onready var _orbit_rig: Node = get_node_or_null(orbit_rig_path)

var _shader_material: ShaderMaterial
var _log_file: FileAccess

func _ready() -> void:
    if _quad:
        _shader_material = ShaderMaterial.new()
        _shader_material.shader = preload("res://shaders/brick_raymarch.gdshader")
        _quad.set_surface_override_material(0, _shader_material)

        var indirection_tex := _build_indirection_texture()
        var atlas_tex := _build_atlas_texture()

        _shader_material.set_shader_parameter("indirection_tex", indirection_tex)
        _shader_material.set_shader_parameter("atlas_tex", atlas_tex)
        _shader_material.set_shader_parameter("grid_min", Vector3(-64.0, -64.0, -64.0))
        _shader_material.set_shader_parameter("grid_max", Vector3(64.0, 64.0, 64.0))
        _shader_material.set_shader_parameter("grid_size", Vector3i(GRID_SIZE, GRID_SIZE, GRID_SIZE))
        _shader_material.set_shader_parameter("brick_counts", Vector3i(BRICK_COUNT, BRICK_COUNT, BRICK_COUNT))
        _shader_material.set_shader_parameter("brick_size", BRICK_SIZE)
        _shader_material.set_shader_parameter("debug_mode", debug_mode)

    if log_every_frame:
        _log_file = FileAccess.open(log_path, FileAccess.WRITE_READ)
        if _log_file:
            _log_file.seek_end()
            _log_file.store_line("--- render log start ---")
        else:
            push_error("Failed to open render log: %s" % log_path)

func _process(delta: float) -> void:
    if _box:
        _box.rotate_y(spin_speed * delta)
        _box.rotate_x(spin_speed * 0.5 * delta)

    if _orbit_rig:
        var rig_target = _orbit_rig.get("target")
        if rig_target is Vector3:
            raymarch_target = rig_target

    if _shader_material and _camera:
        _shader_material.set_shader_parameter("cam_origin", _camera.global_transform.origin)
        _shader_material.set_shader_parameter("cam_target", raymarch_target)
        _shader_material.set_shader_parameter("cam_fov", _camera.fov)
        _shader_material.set_shader_parameter("debug_mode", debug_mode)
        var viewport_size := get_viewport().get_visible_rect().size
        if viewport_size.y > 0.0:
            _shader_material.set_shader_parameter("cam_aspect", viewport_size.x / viewport_size.y)

    if log_every_frame and _log_file:
        var origin := _camera.global_transform.origin if _camera else Vector3.ZERO
        var fov := _camera.fov if _camera else 0.0
        var viewport_size := get_viewport().get_visible_rect().size
        var aspect := viewport_size.x / viewport_size.y if viewport_size.y > 0.0 else 0.0
        var line := "%s dt=%.4f cam=%s fov=%.2f aspect=%.3f debug=%d" % [Time.get_datetime_string_from_system(), delta, origin, fov, aspect, debug_mode]
        _log_file.store_line(line)

func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventKey and event.pressed and event.keycode == KEY_F2:
        debug_mode = (debug_mode + 1) % 3

func _build_indirection_texture() -> ImageTexture3D:
    var images: Array[Image] = []
    for z in range(BRICK_COUNT):
        var img := Image.create(BRICK_COUNT, BRICK_COUNT, false, Image.FORMAT_RF)
        for y in range(BRICK_COUNT):
            for x in range(BRICK_COUNT):
                var index := float(x + y * BRICK_COUNT + z * BRICK_COUNT * BRICK_COUNT)
                var max_index := float(BRICK_COUNT * BRICK_COUNT * BRICK_COUNT - 1)
                var normalized := index / max_index
                img.set_pixel(x, y, Color(normalized, 0.0, 0.0, 1.0))
        images.append(img)

    var tex := ImageTexture3D.new()
    var err := tex.create(Image.FORMAT_RF, BRICK_COUNT, BRICK_COUNT, BRICK_COUNT, false, images)
    if err != OK:
        push_error("Failed to create indirection texture: %s" % err)
    return tex

func _build_atlas_texture() -> ImageTexture3D:
    var images: Array[Image] = []
    for z in range(GRID_SIZE):
        var img := Image.create(GRID_SIZE, GRID_SIZE, false, Image.FORMAT_R8)
        for y in range(GRID_SIZE):
            for x in range(GRID_SIZE):
                var filled := x >= 32 and x < 96 and y >= 32 and y < 96 and z >= 32 and z < 96
                var value := 255 if filled else 0
                img.set_pixel(x, y, Color8(value, 0, 0, 255))
        images.append(img)

    var tex := ImageTexture3D.new()
    var err := tex.create(Image.FORMAT_R8, GRID_SIZE, GRID_SIZE, GRID_SIZE, false, images)
    if err != OK:
        push_error("Failed to create atlas texture: %s" % err)
    return tex
