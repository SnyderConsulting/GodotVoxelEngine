extends Node3D

@export var distance := 40.0
@export var min_distance := 2.0
@export var max_distance := 20.0
@export var rotate_speed := 0.01
@export var zoom_speed := 0.75
@export var pan_speed := 0.01
@export var target := Vector3.ZERO
@export var overlay_enabled := true

var _yaw := 0.0
var _pitch := -0.35
var _dragging := false
var _panning := false

@onready var _camera: Camera3D = $Camera3D
var _overlay_layer: CanvasLayer
var _overlay_panel: ColorRect
var _overlay_label: Label

func _ready() -> void:
    _apply_transform()
    if overlay_enabled:
        _setup_overlay()
        _update_overlay()

func _process(_delta: float) -> void:
    if overlay_enabled and _overlay_label:
        _update_overlay()

func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventMouseButton:
        if event.button_index == MOUSE_BUTTON_LEFT:
            _dragging = event.pressed and not Input.is_key_pressed(KEY_SHIFT)
            _panning = event.pressed and Input.is_key_pressed(KEY_SHIFT)
        if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
            distance = max(min_distance, distance - zoom_speed)
            _apply_transform()
        if event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
            distance = min(max_distance, distance + zoom_speed)
            _apply_transform()
    elif event is InputEventMouseMotion:
        if _dragging:
            _yaw -= event.relative.x * rotate_speed
            _pitch -= event.relative.y * rotate_speed
            _pitch = clamp(_pitch, -1.2, 1.2)
            _apply_transform()
        elif _panning:
            var right = global_transform.basis.x
            var up = global_transform.basis.y
            target -= (right * event.relative.x - up * event.relative.y) * pan_speed
            _apply_transform()

func _apply_transform() -> void:
    position = target
    rotation = Vector3(_pitch, _yaw, 0.0)
    _camera.position = Vector3(0.0, 0.0, distance)
    _camera.look_at(target, Vector3.UP)

func _setup_overlay() -> void:
    if get_node_or_null("OrbitDebugOverlay"):
        return
    _overlay_layer = CanvasLayer.new()
    _overlay_layer.name = "OrbitDebugOverlay"
    _overlay_layer.layer = 100
    add_child(_overlay_layer)

    _overlay_panel = ColorRect.new()
    _overlay_panel.name = "OrbitDebugPanel"
    _overlay_panel.color = Color(0.0, 0.0, 0.0, 0.65)
    _overlay_panel.position = Vector2(12, 12)
    _overlay_panel.size = Vector2(420, 150)
    _overlay_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _overlay_layer.add_child(_overlay_panel)

    _overlay_label = Label.new()
    _overlay_label.name = "OrbitDebugLabel"
    _overlay_label.position = Vector2(8, 6)
    _overlay_label.size = Vector2(404, 140)
    _overlay_label.autowrap_mode = TextServer.AUTOWRAP_OFF
    _overlay_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _overlay_panel.add_child(_overlay_label)

func _update_overlay() -> void:
    var cam_pos := _camera.global_transform.origin if _camera else Vector3.ZERO
    var cam_rot := _camera.global_transform.basis.get_euler() if _camera else Vector3.ZERO
    var cam_rot_deg := Vector3(
        rad_to_deg(cam_rot.x),
        rad_to_deg(cam_rot.y),
        rad_to_deg(cam_rot.z)
    )
    var rig_rot_deg := rotation_degrees

    var text := "Orbit Debug\n"
    text += "yaw: %.4f rad (%.2f deg)\n" % [_yaw, rad_to_deg(_yaw)]
    text += "pitch: %.4f rad (%.2f deg)\n" % [_pitch, rad_to_deg(_pitch)]
    text += "distance: %.3f\n" % distance
    text += "target: %s\n" % _format_vec3(target)
    text += "rig rot deg: %s\n" % _format_vec3(rig_rot_deg)
    text += "cam pos: %s\n" % _format_vec3(cam_pos)
    text += "cam rot deg: %s\n" % _format_vec3(cam_rot_deg)
    if _camera:
        text += "cam fov: %.2f\n" % _camera.fov

    _overlay_label.text = text
    var label_size := _overlay_label.get_minimum_size()
    _overlay_label.size = label_size
    _overlay_panel.size = label_size + Vector2(16, 12)

func _format_vec3(v: Vector3) -> String:
    return "(%.3f, %.3f, %.3f)" % [v.x, v.y, v.z]
