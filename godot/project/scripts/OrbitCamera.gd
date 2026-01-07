extends Node3D

@export var distance := 40.0
@export var min_distance := 2.0
@export var max_distance := 20.0
@export var rotate_speed := 0.01
@export var zoom_speed := 0.75
@export var pan_speed := 0.01
@export var target := Vector3.ZERO

var _yaw := 0.0
var _pitch := -0.35
var _dragging := false
var _panning := false

@onready var _camera: Camera3D = $Camera3D

func _ready() -> void:
    _clamp_distance()
    _apply_transform()

func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventMouseButton:
        if event.button_index == MOUSE_BUTTON_LEFT:
            _dragging = event.pressed and not Input.is_key_pressed(KEY_SHIFT)
            _panning = event.pressed and Input.is_key_pressed(KEY_SHIFT)
        if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
            distance -= zoom_speed
            _clamp_distance()
            _apply_transform()
        if event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
            distance += zoom_speed
            _clamp_distance()
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
    _clamp_distance()
    position = target
    rotation = Vector3(_pitch, _yaw, 0.0)
    _camera.position = Vector3(0.0, 0.0, distance)
    _camera.look_at(target, Vector3.UP)

func _clamp_distance() -> void:
    if max_distance < min_distance:
        max_distance = min_distance
    distance = clamp(distance, min_distance, max_distance)
