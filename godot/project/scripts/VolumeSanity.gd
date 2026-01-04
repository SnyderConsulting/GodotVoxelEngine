extends Node

@export var output_mesh_path: NodePath = NodePath("HelloCamera/SanityQuad")

const SANITY_SHADER: Shader = preload("res://shaders/volume_sanity.gdshader")
const TEX_SIZE := 16

var _shader_material: ShaderMaterial

func _ready() -> void:
	var quad := get_node(output_mesh_path) as MeshInstance3D
	if quad == null:
		push_error("Sanity quad not found.")
		return
	_shader_material = quad.material_override as ShaderMaterial
	if _shader_material == null:
		_shader_material = ShaderMaterial.new()
		quad.material_override = _shader_material
	_shader_material.shader = SANITY_SHADER

	var tex := _build_sanity_texture()
	_shader_material.set_shader_parameter("sanity_tex", tex)
	_shader_material.set_shader_parameter("slice", 0.5)

func _build_sanity_texture() -> ImageTexture3D:
	var images: Array[Image] = []
	for z in range(TEX_SIZE):
		var img := Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
		for y in range(TEX_SIZE):
			for x in range(TEX_SIZE):
				var r := float(x) / float(TEX_SIZE - 1)
				var g := float(y) / float(TEX_SIZE - 1)
				var b := float(z) / float(TEX_SIZE - 1)
				img.set_pixel(x, y, Color(r, g, b, 1.0))
		images.append(img)

	var tex := ImageTexture3D.new()
	var err := tex.create(Image.FORMAT_RGBA8, TEX_SIZE, TEX_SIZE, TEX_SIZE, false, images)
	if err != OK:
		push_error("Failed to create sanity texture: %s" % err)
	return tex
