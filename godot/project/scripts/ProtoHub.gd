extends Control

@export var tumbler_scene: String = "res://scenes/TumblerTest.tscn"
@export var hourglass_scene: String = "res://scenes/HourglassTest.tscn"
@export var template_scene: String = "res://scenes/GlassSandTemplate.tscn"
@export var plinko_scene: String = "res://scenes/PlinkoTest.tscn"
@export var paint_scene: String = "res://scenes/PaintTest.tscn"
@export var voxel_game_scene: String = "res://scenes/VoxelGame.tscn"
@export var stone_pillar_scene: String = "res://scenes/StonePillarTest.tscn"
@export var jelly_scene: String = "res://scenes/JellyTest.tscn"

@onready var _tumbler_button: Button = $Margin/VBox/TumblerButton
@onready var _hourglass_button: Button = $Margin/VBox/HourglassButton
@onready var _template_button: Button = $Margin/VBox/TemplateButton
@onready var _plinko_button: Button = $Margin/VBox/PlinkoButton
@onready var _paint_button: Button = $Margin/VBox/PaintButton
@onready var _voxel_game_button: Button = $Margin/VBox/VoxelGameButton
@onready var _stone_pillar_button: Button = $Margin/VBox/StonePillarButton
@onready var _jelly_button: Button = $Margin/VBox/JellyButton

func _ready() -> void:
    _tumbler_button.pressed.connect(_on_tumbler_pressed)
    _hourglass_button.pressed.connect(_on_hourglass_pressed)
    _template_button.pressed.connect(_on_template_pressed)
    _plinko_button.pressed.connect(_on_plinko_pressed)
    _paint_button.pressed.connect(_on_paint_pressed)
    _voxel_game_button.pressed.connect(_on_voxel_game_pressed)
    _stone_pillar_button.pressed.connect(_on_stone_pillar_pressed)
    _jelly_button.pressed.connect(_on_jelly_pressed)
    _tumbler_button.grab_focus()

func _on_tumbler_pressed() -> void:
    get_tree().change_scene_to_file(tumbler_scene)

func _on_hourglass_pressed() -> void:
    get_tree().change_scene_to_file(hourglass_scene)

func _on_template_pressed() -> void:
    get_tree().change_scene_to_file(template_scene)

func _on_plinko_pressed() -> void:
    get_tree().change_scene_to_file(plinko_scene)

func _on_paint_pressed() -> void:
    get_tree().change_scene_to_file(paint_scene)

func _on_voxel_game_pressed() -> void:
    get_tree().change_scene_to_file(voxel_game_scene)

func _on_stone_pillar_pressed() -> void:
    get_tree().change_scene_to_file(stone_pillar_scene)

func _on_jelly_pressed() -> void:
    get_tree().change_scene_to_file(jelly_scene)
