extends Control

@export var radius_px: float = 8.0
@export var color: Color = Color(1, 1, 1, 0.6)

func _ready() -> void:
    mouse_filter = Control.MOUSE_FILTER_IGNORE

func _process(_delta: float) -> void:
    queue_redraw()

func _draw() -> void:
    draw_circle(Vector2(radius_px, radius_px), radius_px, color)
