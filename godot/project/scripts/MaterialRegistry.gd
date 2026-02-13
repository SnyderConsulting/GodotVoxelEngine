extends RefCounted
class_name MaterialRegistry

const SAND_ID := 1
const WATER_ID := 2
const OXYGEN_ID := 3
const STONE_ID := 4
const FIRE_ID := 5
const METAL_ID := 6
const GLASS_ID := 8
const INVISIBLE_ID := 9
const GRASS_ID := 12
const DIRT_ID := 13
const ORE_ID := 14
const WOOD_ID := 15
const TORCH_ID := 16

const DEFAULT_MATERIALS := {
    SAND_ID: {
        "id": SAND_ID,
        "name": "sand",
        "mass": 1.6,
        "friction": 0.7,
        "cohesion": 0.2,
        "resistance": 0.6,
        "drag": 0.35,
        "support_bonus": 0.0,
        "lateral_bias": -0.15,
        "gravity_bias": 1.2,
        "albedo_r": 0.90,
        "albedo_g": 0.70,
        "albedo_b": 0.40,
        "roughness": 0.90,
        "metallic": 0.0,
        "specular": 0.08,
        "emissive_r": 0.0,
        "emissive_g": 0.0,
        "emissive_b": 0.0,
        "emissive_strength": 0.0,
    },
    WATER_ID: {
        "id": WATER_ID,
        "name": "water",
        "mass": 1.0,
        "friction": 0.02,
        "cohesion": 0.04,
        "resistance": 0.08,
        "drag": 0.12,
        "support_bonus": 0.02,
        "lateral_bias": 1.2,
        "gravity_bias": 1.0,
        "albedo_r": 0.18,
        "albedo_g": 0.58,
        "albedo_b": 0.92,
        "roughness": 0.015,
        "metallic": 0.0,
        "specular": 0.98,
        "emissive_r": 0.0,
        "emissive_g": 0.0,
        "emissive_b": 0.0,
        "emissive_strength": 0.0,
    },
    OXYGEN_ID: {
        "id": OXYGEN_ID,
        "name": "oxygen",
        "mass": 0.05,
        "friction": 0.0,
        "cohesion": 0.0,
        "resistance": 0.0,
        "drag": 0.01,
        "support_bonus": 0.0,
        "lateral_bias": 0.0,
        "gravity_bias": 0.0,
        "albedo_r": 0.65,
        "albedo_g": 0.72,
        "albedo_b": 0.84,
        "roughness": 1.0,
        "metallic": 0.0,
        "specular": 0.0,
        "emissive_r": 0.0,
        "emissive_g": 0.0,
        "emissive_b": 0.0,
        "emissive_strength": 0.0,
    },
    STONE_ID: {
        "id": STONE_ID,
        "name": "stone",
        "mass": 4.0,
        "friction": 1.0,
        "cohesion": 1.5,
        "resistance": 8.0,
        "drag": 0.2,
        "support_bonus": 0.0,
        "lateral_bias": -0.5,
        "gravity_bias": 0.0,
        "albedo_r": 0.48,
        "albedo_g": 0.50,
        "albedo_b": 0.53,
        "roughness": 0.96,
        "metallic": 0.0,
        "specular": 0.06,
        "emissive_r": 0.0,
        "emissive_g": 0.0,
        "emissive_b": 0.0,
        "emissive_strength": 0.0,
    },
    FIRE_ID: {
        "id": FIRE_ID,
        "name": "fire",
        "mass": 0.08,
        "friction": 0.0,
        "cohesion": 0.02,
        "resistance": 0.01,
        "drag": 0.05,
        "support_bonus": 0.0,
        "lateral_bias": 0.8,
        "gravity_bias": -0.9,
        "albedo_r": 1.00,
        "albedo_g": 0.42,
        "albedo_b": 0.08,
        "roughness": 0.22,
        "metallic": 0.0,
        "specular": 0.02,
        "emissive_r": 1.00,
        "emissive_g": 0.44,
        "emissive_b": 0.12,
        "emissive_strength": 1.8,
    },
    METAL_ID: {
        "id": METAL_ID,
        "name": "metal",
        "mass": 6.8,
        "friction": 0.9,
        "cohesion": 1.2,
        "resistance": 9.5,
        "drag": 0.18,
        "support_bonus": 0.0,
        "lateral_bias": -0.45,
        "gravity_bias": 0.0,
        "albedo_r": 0.72,
        "albedo_g": 0.75,
        "albedo_b": 0.80,
        "roughness": 0.16,
        "metallic": 1.0,
        "specular": 0.95,
        "emissive_r": 0.0,
        "emissive_g": 0.0,
        "emissive_b": 0.0,
        "emissive_strength": 0.0,
    },
    GLASS_ID: {
        "id": GLASS_ID,
        "name": "glass",
        "mass": 3.0,
        "friction": 10.0,
        "cohesion": 2.0,
        "resistance": 10.0,
        "drag": 2.0,
        "support_bonus": 0.0,
        "lateral_bias": -1.0,
        "gravity_bias": 0.0,
        "albedo_r": 0.80,
        "albedo_g": 0.90,
        "albedo_b": 1.00,
        "roughness": 0.01,
        "metallic": 0.0,
        "specular": 1.0,
        "emissive_r": 0.0,
        "emissive_g": 0.0,
        "emissive_b": 0.0,
        "emissive_strength": 0.0,
    },
    INVISIBLE_ID: {
        "id": INVISIBLE_ID,
        "name": "invisible",
        "mass": 3.0,
        "friction": 10.0,
        "cohesion": 2.0,
        "resistance": 10.0,
        "drag": 2.0,
        "support_bonus": 0.0,
        "lateral_bias": -1.0,
        "gravity_bias": 0.0,
        "albedo_r": 0.0,
        "albedo_g": 0.0,
        "albedo_b": 0.0,
        "roughness": 1.0,
        "metallic": 0.0,
        "specular": 0.0,
        "emissive_r": 0.0,
        "emissive_g": 0.0,
        "emissive_b": 0.0,
        "emissive_strength": 0.0,
    },
    GRASS_ID: {
        "id": GRASS_ID,
        "name": "grass",
        "mass": 2.0,
        "friction": 1.2,
        "cohesion": 1.2,
        "resistance": 10.0,
        "drag": 0.25,
        "support_bonus": 0.0,
        "lateral_bias": 0.0,
        "gravity_bias": 0.0,
        "albedo_r": 0.24,
        "albedo_g": 0.62,
        "albedo_b": 0.24,
        "roughness": 0.95,
        "metallic": 0.0,
        "specular": 0.04,
        "emissive_r": 0.0,
        "emissive_g": 0.0,
        "emissive_b": 0.0,
        "emissive_strength": 0.0,
    },
    DIRT_ID: {
        "id": DIRT_ID,
        "name": "dirt",
        "mass": 2.2,
        "friction": 1.1,
        "cohesion": 1.3,
        "resistance": 10.5,
        "drag": 0.25,
        "support_bonus": 0.0,
        "lateral_bias": 0.0,
        "gravity_bias": 0.0,
        "albedo_r": 0.44,
        "albedo_g": 0.30,
        "albedo_b": 0.16,
        "roughness": 0.97,
        "metallic": 0.0,
        "specular": 0.03,
        "emissive_r": 0.0,
        "emissive_g": 0.0,
        "emissive_b": 0.0,
        "emissive_strength": 0.0,
    },
    ORE_ID: {
        "id": ORE_ID,
        "name": "ore",
        "mass": 6.0,
        "friction": 1.0,
        "cohesion": 1.6,
        "resistance": 11.0,
        "drag": 0.18,
        "support_bonus": 0.0,
        "lateral_bias": 0.0,
        "gravity_bias": 0.0,
        "albedo_r": 0.62,
        "albedo_g": 0.58,
        "albedo_b": 0.52,
        "roughness": 0.40,
        "metallic": 0.35,
        "specular": 0.55,
        "emissive_r": 0.0,
        "emissive_g": 0.0,
        "emissive_b": 0.0,
        "emissive_strength": 0.0,
    },

    WOOD_ID: {
        "id": WOOD_ID,
        "name": "wood",
        "mass": 2.4,
        "friction": 1.05,
        "cohesion": 1.1,
        "resistance": 9.0,
        "drag": 0.22,
        "support_bonus": 0.0,
        "lateral_bias": 0.0,
        "gravity_bias": 0.0,
        "albedo_r": 0.48,
        "albedo_g": 0.32,
        "albedo_b": 0.18,
        "roughness": 0.82,
        "metallic": 0.0,
        "specular": 0.06,
        "emissive_r": 0.0,
        "emissive_g": 0.0,
        "emissive_b": 0.0,
        "emissive_strength": 0.0,
    },
    TORCH_ID: {
        "id": TORCH_ID,
        "name": "torch",
        "mass": 0.08,
        "friction": 0.0,
        "cohesion": 0.02,
        "resistance": 0.01,
        "drag": 0.05,
        "support_bonus": 0.0,
        "lateral_bias": 0.8,
        "gravity_bias": -0.9,
        "albedo_r": 1.00,
        "albedo_g": 0.44,
        "albedo_b": 0.10,
        "roughness": 0.18,
        "metallic": 0.0,
        "specular": 0.03,
        "emissive_r": 1.00,
        "emissive_g": 0.58,
        "emissive_b": 0.20,
        "emissive_strength": 2.0,
    },
}

static func is_static_material(material_id: int) -> bool:
    # Static materials are written into the MPM static atlas (they do not become particles).
    return (
        material_id == GLASS_ID
        or material_id == INVISIBLE_ID
        or material_id == WOOD_ID
        or material_id == TORCH_ID
    )

static func load_materials(path: String) -> Dictionary:
    var materials: Dictionary = {}
    for id_variant in DEFAULT_MATERIALS.keys():
        var mid := int(id_variant)
        materials[mid] = (DEFAULT_MATERIALS[mid] as Dictionary).duplicate()

    var parsed := _read_material_array(path)
    for item in parsed:
        if typeof(item) != TYPE_DICTIONARY:
            continue
        var src: Dictionary = item
        var mid := int(src.get("id", -1))
        if mid < 0:
            continue
        var merged: Dictionary = {}
        var default_src: Variant = materials.get(mid, {})
        if typeof(default_src) == TYPE_DICTIONARY:
            merged = (default_src as Dictionary).duplicate()
        for key in src.keys():
            merged[key] = src[key]
        merged["id"] = mid
        materials[mid] = merged
    return materials

static func load_material_name_map(path: String) -> Dictionary:
    var out: Dictionary = {}
    var materials: Dictionary = load_materials(path)
    for id_variant in materials.keys():
        var mid := int(id_variant)
        var src: Variant = materials[id_variant]
        if typeof(src) != TYPE_DICTIONARY:
            continue
        var d: Dictionary = src
        out[mid] = str(d.get("name", "mat_%d" % mid))
    return out

static func load_mass_map(path: String) -> Dictionary:
    var out: Dictionary = {}
    var materials: Dictionary = load_materials(path)
    for id_variant in materials.keys():
        var mid := int(id_variant)
        var src: Variant = materials[id_variant]
        if typeof(src) != TYPE_DICTIONARY:
            continue
        var d: Dictionary = src
        out[mid] = float(d.get("mass", 0.0))
    return out

static func build_props_buffer(path: String, gravity_bias_default: float = 1.0) -> PackedByteArray:
    # Each material uses 20 floats (5 x vec4):
    # vec4[0] = [mass, friction, cohesion, resistance]
    # vec4[1] = [drag, support_bonus, lateral_bias, gravity_bias]
    # vec4[2] = [albedo_r, albedo_g, albedo_b, roughness]
    # vec4[3] = [emissive_r, emissive_g, emissive_b, emissive_strength]
    # vec4[4] = [metallic, specular, reserved, reserved]
    var materials: Dictionary = load_materials(path)
    var max_id := 0
    for id_variant in materials.keys():
        max_id = maxi(max_id, int(id_variant))
    var count := max_id + 1
    var floats := PackedFloat32Array()
    floats.resize(count * 20)
    for i in range(count):
        var src: Variant = materials.get(i, {})
        var d: Dictionary = {}
        if typeof(src) == TYPE_DICTIONARY:
            d = src
        var base := i * 20
        var fallback_albedo: Vector3 = _fallback_albedo(i)
        floats[base + 0] = float(d.get("mass", 0.0))
        floats[base + 1] = float(d.get("friction", 0.0))
        floats[base + 2] = float(d.get("cohesion", 0.0))
        floats[base + 3] = float(d.get("resistance", 0.0))
        floats[base + 4] = float(d.get("drag", 0.0))
        floats[base + 5] = float(d.get("support_bonus", 0.0))
        floats[base + 6] = float(d.get("lateral_bias", 0.0))
        floats[base + 7] = float(d.get("gravity_bias", gravity_bias_default))
        floats[base + 8] = float(d.get("albedo_r", fallback_albedo.x))
        floats[base + 9] = float(d.get("albedo_g", fallback_albedo.y))
        floats[base + 10] = float(d.get("albedo_b", fallback_albedo.z))
        floats[base + 11] = float(d.get("roughness", 0.8))
        floats[base + 12] = float(d.get("emissive_r", 0.0))
        floats[base + 13] = float(d.get("emissive_g", 0.0))
        floats[base + 14] = float(d.get("emissive_b", 0.0))
        floats[base + 15] = float(d.get("emissive_strength", 0.0))
        floats[base + 16] = float(d.get("metallic", 0.0))
        floats[base + 17] = float(d.get("specular", 0.5))
        floats[base + 18] = 0.0
        floats[base + 19] = 0.0
    return floats.to_byte_array()

static func _fallback_albedo(material_id: int) -> Vector3:
    if material_id <= 0:
        return Vector3.ZERO
    var palette: Array = [
        Vector3(0.90, 0.70, 0.40),
        Vector3(0.20, 0.60, 0.90),
        Vector3(0.90, 0.30, 0.30),
        Vector3(0.30, 0.90, 0.40),
        Vector3(0.85, 0.85, 0.20),
        Vector3(0.70, 0.40, 0.90),
        Vector3(0.40, 0.90, 0.90),
        Vector3(0.70, 0.70, 0.70),
    ]
    var idx := (material_id - 1) % palette.size()
    var c: Vector3 = palette[idx]
    return c

static func _read_material_array(path: String) -> Array:
    if path.is_empty() or !FileAccess.file_exists(path):
        return []
    var text := FileAccess.get_file_as_string(path)
    if text.is_empty():
        return []
    var parsed: Variant = JSON.parse_string(text)
    if typeof(parsed) != TYPE_DICTIONARY:
        return []
    var parsed_dict: Dictionary = parsed
    var mats: Variant = parsed_dict.get("materials", [])
    if typeof(mats) != TYPE_ARRAY:
        return []
    return mats as Array
