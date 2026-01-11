extends Control

@export var tumbler_scene: String = "res://scenes/TumblerTest.tscn"
@export var hourglass_scene: String = "res://scenes/HourglassTest.tscn"
@export var template_scene: String = "res://scenes/GlassSandTemplate.tscn"

@onready var _tumbler_button: Button = $Margin/VBox/TumblerButton
@onready var _hourglass_button: Button = $Margin/VBox/HourglassButton
@onready var _template_button: Button = $Margin/VBox/TemplateButton

func _ready() -> void:
    _tumbler_button.pressed.connect(_on_tumbler_pressed)
    _hourglass_button.pressed.connect(_on_hourglass_pressed)
    _template_button.pressed.connect(_on_template_pressed)
    _tumbler_button.grab_focus()

func _on_tumbler_pressed() -> void:
    get_tree().change_scene_to_file(tumbler_scene)

func _on_hourglass_pressed() -> void:
    get_tree().change_scene_to_file(hourglass_scene)

func _on_template_pressed() -> void:
    get_tree().change_scene_to_file(template_scene)
