extends RefCounted
class_name MaterialRegistry

const SAND_ID := 1
const WATER_ID := 2
const OXYGEN_ID := 3
const STONE_ID := 4
const GLASS_ID := 8
const INVISIBLE_ID := 9

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
    },
}

static func is_static_material(material_id: int) -> bool:
    return material_id == GLASS_ID or material_id == INVISIBLE_ID

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
    # Each material uses 8 floats:
    # [mass, friction, cohesion, resistance, drag, support_bonus, lateral_bias, gravity_bias]
    var materials: Dictionary = load_materials(path)
    var max_id := 0
    for id_variant in materials.keys():
        max_id = maxi(max_id, int(id_variant))
    var count := max_id + 1
    var floats := PackedFloat32Array()
    floats.resize(count * 8)
    for i in range(count):
        var src: Variant = materials.get(i, {})
        var d: Dictionary = {}
        if typeof(src) == TYPE_DICTIONARY:
            d = src
        floats[i * 8 + 0] = float(d.get("mass", 0.0))
        floats[i * 8 + 1] = float(d.get("friction", 0.0))
        floats[i * 8 + 2] = float(d.get("cohesion", 0.0))
        floats[i * 8 + 3] = float(d.get("resistance", 0.0))
        floats[i * 8 + 4] = float(d.get("drag", 0.0))
        floats[i * 8 + 5] = float(d.get("support_bonus", 0.0))
        floats[i * 8 + 6] = float(d.get("lateral_bias", 0.0))
        floats[i * 8 + 7] = float(d.get("gravity_bias", gravity_bias_default))
    return floats.to_byte_array()

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
