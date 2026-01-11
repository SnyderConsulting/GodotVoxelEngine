extends Control
@export var diag_enabled: bool = false

@export var voxel_renderer_path: NodePath

@onready var _renderer: Node = get_node_or_null(voxel_renderer_path)
@onready var _gravity_yaw_slider: HSlider = $Panel/Margin/VBox/GravityYaw/Slider
@onready var _gravity_yaw_value: Label = $Panel/Margin/VBox/GravityYaw/Value
@onready var _gravity_pitch_slider: HSlider = $Panel/Margin/VBox/GravityPitch/Slider
@onready var _gravity_pitch_value: Label = $Panel/Margin/VBox/GravityPitch/Value
@onready var _world_yaw_slider: HSlider = $Panel/Margin/VBox/WorldYaw/Slider
@onready var _world_yaw_value: Label = $Panel/Margin/VBox/WorldYaw/Value
@onready var _world_pitch_slider: HSlider = $Panel/Margin/VBox/WorldPitch/Slider
@onready var _world_pitch_value: Label = $Panel/Margin/VBox/WorldPitch/Value
@onready var _world_roll_slider: HSlider = $Panel/Margin/VBox/WorldRoll/Slider
@onready var _world_roll_value: Label = $Panel/Margin/VBox/WorldRoll/Value
@onready var _reset_button: Button = $Panel/Margin/VBox/ResetButton

func _ready() -> void:
    if _renderer == null:
        push_error("SceneControls missing VoxelRenderer.")
        return

    _gravity_yaw_slider.value = 0.0
    _gravity_pitch_slider.value = 0.0
    _world_yaw_slider.value = rad_to_deg(_renderer.world_rotation.y)
    _world_pitch_slider.value = rad_to_deg(_renderer.world_rotation.x)
    _world_roll_slider.value = rad_to_deg(_renderer.world_rotation.z)

    _gravity_yaw_slider.value_changed.connect(_on_gravity_changed)
    _gravity_pitch_slider.value_changed.connect(_on_gravity_changed)
    _world_yaw_slider.value_changed.connect(_on_world_changed)
    _world_pitch_slider.value_changed.connect(_on_world_changed)
    _world_roll_slider.value_changed.connect(_on_world_changed)
    _reset_button.pressed.connect(_on_reset_pressed)

    _apply_gravity()
    _apply_world_rotation()
    _update_labels()
    _diag("ready world_rot_deg=(%.0f, %.0f, %.0f)" % [
        _world_pitch_slider.value,
        _world_yaw_slider.value,
        _world_roll_slider.value
    ])

func _on_gravity_changed(_value: float) -> void:
    _apply_gravity()
    _update_labels()
    _diag("gravity yaw=%.1f pitch=%.1f dir=%s" % [
        _gravity_yaw_slider.value,
        _gravity_pitch_slider.value,
        str(_renderer.gravity_dir) if _renderer else "null"
    ])

func _on_world_changed(_value: float) -> void:
    _apply_world_rotation()
    _update_labels()
    _diag("world yaw=%.1f pitch=%.1f roll=%.1f rot=%s" % [
        _world_yaw_slider.value,
        _world_pitch_slider.value,
        _world_roll_slider.value,
        str(_renderer.world_rotation) if _renderer else "null"
    ])

func _on_reset_pressed() -> void:
    _gravity_yaw_slider.value = 0.0
    _gravity_pitch_slider.value = 0.0
    _world_yaw_slider.value = 0.0
    _world_pitch_slider.value = 0.0
    _world_roll_slider.value = 0.0
    _apply_gravity()
    _apply_world_rotation()
    _update_labels()
    _diag("reset sliders to zero")

func _apply_gravity() -> void:
    var yaw := deg_to_rad(_gravity_yaw_slider.value)
    var pitch := deg_to_rad(_gravity_pitch_slider.value)
    var basis := Basis.from_euler(Vector3(pitch, yaw, 0.0))
    _renderer.gravity_dir = (basis * Vector3.DOWN).normalized()

func _apply_world_rotation() -> void:
    _renderer.world_rotation = Vector3(
        deg_to_rad(_world_pitch_slider.value),
        deg_to_rad(_world_yaw_slider.value),
        deg_to_rad(_world_roll_slider.value)
    )

func _update_labels() -> void:
    _gravity_yaw_value.text = "%.0f" % _gravity_yaw_slider.value
    _gravity_pitch_value.text = "%.0f" % _gravity_pitch_slider.value
    _world_yaw_value.text = "%.0f" % _world_yaw_slider.value
    _world_pitch_value.text = "%.0f" % _world_pitch_slider.value
    _world_roll_value.text = "%.0f" % _world_roll_slider.value

func _diag(msg: String) -> void:
    if !diag_enabled:
        return
    print("SceneControls diag | %s" % msg)
