extends Node

@export var output_mesh_path: NodePath = NodePath("HelloCamera/RaymarchQuad")

@onready var _mesh: MeshInstance3D = get_node(output_mesh_path) as MeshInstance3D

func _ready() -> void:
	if _mesh == null:
		push_error("Raymarch quad not found for mesh swap.")
		return
	var plane := PlaneMesh.new()
	plane.size = Vector2(2, 2)
	_mesh.mesh = plane