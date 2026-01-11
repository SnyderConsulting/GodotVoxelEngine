#include "automation_server.h"

#include "core/config/engine.h"
#include "core/input/input.h"
#include "core/io/json.h"
#include "core/object/object.h"
#include "core/os/os.h"
#include "scene/main/node.h"
#include "scene/main/scene_tree.h"
#include "scene/main/viewport.h"
#include "scene/main/window.h"
#include "scene/3d/mesh_instance_3d.h"
#include "scene/resources/material.h"
#include "servers/rendering/rendering_device.h"
#include "servers/rendering/rendering_server.h"

static bool _extract_number(const Variant &p_value, double &r_out) {
	switch (p_value.get_type()) {
		case Variant::INT:
			r_out = double(int64_t(p_value));
			return true;
		case Variant::FLOAT:
			r_out = double(p_value);
			return true;
		case Variant::BOOL:
			r_out = bool(p_value) ? 1.0 : 0.0;
			return true;
		default:
			return false;
	}
}

static bool _extract_int(const Variant &p_value, int64_t &r_out) {
	double tmp = 0.0;
	if (!_extract_number(p_value, tmp)) {
		return false;
	}
	r_out = int64_t(tmp);
	return true;
}

static bool _dict_get_number(const Dictionary &p_dict, const char *p_key, double &r_out) {
	if (!p_dict.has(p_key)) {
		return false;
	}
	return _extract_number(p_dict[p_key], r_out);
}

static bool _dict_get_int(const Dictionary &p_dict, const char *p_key, int64_t &r_out) {
	if (!p_dict.has(p_key)) {
		return false;
	}
	return _extract_int(p_dict[p_key], r_out);
}

static bool _coerce_vector2(const Variant &p_value, Vector2 &r_out) {
	if (p_value.get_type() == Variant::ARRAY) {
		Array arr = p_value;
		if (arr.size() < 2) {
			return false;
		}
		double x = 0.0;
		double y = 0.0;
		if (!_extract_number(arr[0], x) || !_extract_number(arr[1], y)) {
			return false;
		}
		r_out = Vector2(x, y);
		return true;
	}
	if (p_value.get_type() == Variant::DICTIONARY) {
		Dictionary dict = p_value;
		double x = 0.0;
		double y = 0.0;
		if (!_dict_get_number(dict, "x", x) || !_dict_get_number(dict, "y", y)) {
			return false;
		}
		r_out = Vector2(x, y);
		return true;
	}
	return false;
}

static bool _coerce_vector2i(const Variant &p_value, Vector2i &r_out) {
	if (p_value.get_type() == Variant::ARRAY) {
		Array arr = p_value;
		if (arr.size() < 2) {
			return false;
		}
		int64_t x = 0;
		int64_t y = 0;
		if (!_extract_int(arr[0], x) || !_extract_int(arr[1], y)) {
			return false;
		}
		r_out = Vector2i(int(x), int(y));
		return true;
	}
	if (p_value.get_type() == Variant::DICTIONARY) {
		Dictionary dict = p_value;
		int64_t x = 0;
		int64_t y = 0;
		if (!_dict_get_int(dict, "x", x) || !_dict_get_int(dict, "y", y)) {
			return false;
		}
		r_out = Vector2i(int(x), int(y));
		return true;
	}
	return false;
}

static bool _coerce_vector3(const Variant &p_value, Vector3 &r_out) {
	if (p_value.get_type() == Variant::ARRAY) {
		Array arr = p_value;
		if (arr.size() < 3) {
			return false;
		}
		double x = 0.0;
		double y = 0.0;
		double z = 0.0;
		if (!_extract_number(arr[0], x) || !_extract_number(arr[1], y) || !_extract_number(arr[2], z)) {
			return false;
		}
		r_out = Vector3(x, y, z);
		return true;
	}
	if (p_value.get_type() == Variant::DICTIONARY) {
		Dictionary dict = p_value;
		double x = 0.0;
		double y = 0.0;
		double z = 0.0;
		if (!_dict_get_number(dict, "x", x) || !_dict_get_number(dict, "y", y) || !_dict_get_number(dict, "z", z)) {
			return false;
		}
		r_out = Vector3(x, y, z);
		return true;
	}
	return false;
}

static bool _coerce_vector3i(const Variant &p_value, Vector3i &r_out) {
	if (p_value.get_type() == Variant::ARRAY) {
		Array arr = p_value;
		if (arr.size() < 3) {
			return false;
		}
		int64_t x = 0;
		int64_t y = 0;
		int64_t z = 0;
		if (!_extract_int(arr[0], x) || !_extract_int(arr[1], y) || !_extract_int(arr[2], z)) {
			return false;
		}
		r_out = Vector3i(int(x), int(y), int(z));
		return true;
	}
	if (p_value.get_type() == Variant::DICTIONARY) {
		Dictionary dict = p_value;
		int64_t x = 0;
		int64_t y = 0;
		int64_t z = 0;
		if (!_dict_get_int(dict, "x", x) || !_dict_get_int(dict, "y", y) || !_dict_get_int(dict, "z", z)) {
			return false;
		}
		r_out = Vector3i(int(x), int(y), int(z));
		return true;
	}
	return false;
}

static bool _coerce_vector4(const Variant &p_value, Vector4 &r_out) {
	if (p_value.get_type() == Variant::ARRAY) {
		Array arr = p_value;
		if (arr.size() < 4) {
			return false;
		}
		double x = 0.0;
		double y = 0.0;
		double z = 0.0;
		double w = 0.0;
		if (!_extract_number(arr[0], x) || !_extract_number(arr[1], y) || !_extract_number(arr[2], z) || !_extract_number(arr[3], w)) {
			return false;
		}
		r_out = Vector4(x, y, z, w);
		return true;
	}
	if (p_value.get_type() == Variant::DICTIONARY) {
		Dictionary dict = p_value;
		double x = 0.0;
		double y = 0.0;
		double z = 0.0;
		double w = 0.0;
		if (!_dict_get_number(dict, "x", x) || !_dict_get_number(dict, "y", y) || !_dict_get_number(dict, "z", z) || !_dict_get_number(dict, "w", w)) {
			return false;
		}
		r_out = Vector4(x, y, z, w);
		return true;
	}
	return false;
}

static bool _coerce_vector4i(const Variant &p_value, Vector4i &r_out) {
	if (p_value.get_type() == Variant::ARRAY) {
		Array arr = p_value;
		if (arr.size() < 4) {
			return false;
		}
		int64_t x = 0;
		int64_t y = 0;
		int64_t z = 0;
		int64_t w = 0;
		if (!_extract_int(arr[0], x) || !_extract_int(arr[1], y) || !_extract_int(arr[2], z) || !_extract_int(arr[3], w)) {
			return false;
		}
		r_out = Vector4i(int(x), int(y), int(z), int(w));
		return true;
	}
	if (p_value.get_type() == Variant::DICTIONARY) {
		Dictionary dict = p_value;
		int64_t x = 0;
		int64_t y = 0;
		int64_t z = 0;
		int64_t w = 0;
		if (!_dict_get_int(dict, "x", x) || !_dict_get_int(dict, "y", y) || !_dict_get_int(dict, "z", z) || !_dict_get_int(dict, "w", w)) {
			return false;
		}
		r_out = Vector4i(int(x), int(y), int(z), int(w));
		return true;
	}
	return false;
}

static bool _coerce_color(const Variant &p_value, Color &r_out) {
	if (p_value.get_type() == Variant::ARRAY) {
		Array arr = p_value;
		if (arr.size() < 3) {
			return false;
		}
		double r = 0.0;
		double g = 0.0;
		double b = 0.0;
		double a = 1.0;
		if (!_extract_number(arr[0], r) || !_extract_number(arr[1], g) || !_extract_number(arr[2], b)) {
			return false;
		}
		if (arr.size() >= 4 && !_extract_number(arr[3], a)) {
			return false;
		}
		r_out = Color(r, g, b, a);
		return true;
	}
	if (p_value.get_type() == Variant::DICTIONARY) {
		Dictionary dict = p_value;
		double r = 0.0;
		double g = 0.0;
		double b = 0.0;
		double a = 1.0;
		if (!_dict_get_number(dict, "r", r) || !_dict_get_number(dict, "g", g) || !_dict_get_number(dict, "b", b)) {
			return false;
		}
		if (dict.has("a") && !_dict_get_number(dict, "a", a)) {
			return false;
		}
		r_out = Color(r, g, b, a);
		return true;
	}
	return false;
}

static bool _coerce_rect2(const Variant &p_value, Rect2 &r_out) {
	if (p_value.get_type() == Variant::ARRAY) {
		Array arr = p_value;
		if (arr.size() < 4) {
			return false;
		}
		double x = 0.0;
		double y = 0.0;
		double w = 0.0;
		double h = 0.0;
		if (!_extract_number(arr[0], x) || !_extract_number(arr[1], y) || !_extract_number(arr[2], w) || !_extract_number(arr[3], h)) {
			return false;
		}
		r_out = Rect2(x, y, w, h);
		return true;
	}
	if (p_value.get_type() == Variant::DICTIONARY) {
		Dictionary dict = p_value;
		double x = 0.0;
		double y = 0.0;
		double w = 0.0;
		double h = 0.0;
		if (!_dict_get_number(dict, "x", x) || !_dict_get_number(dict, "y", y)) {
			return false;
		}
		if (!_dict_get_number(dict, "w", w)) {
			if (!_dict_get_number(dict, "width", w)) {
				return false;
			}
		}
		if (!_dict_get_number(dict, "h", h)) {
			if (!_dict_get_number(dict, "height", h)) {
				return false;
			}
		}
		r_out = Rect2(x, y, w, h);
		return true;
	}
	return false;
}

static bool _coerce_rect2i(const Variant &p_value, Rect2i &r_out) {
	if (p_value.get_type() == Variant::ARRAY) {
		Array arr = p_value;
		if (arr.size() < 4) {
			return false;
		}
		int64_t x = 0;
		int64_t y = 0;
		int64_t w = 0;
		int64_t h = 0;
		if (!_extract_int(arr[0], x) || !_extract_int(arr[1], y) || !_extract_int(arr[2], w) || !_extract_int(arr[3], h)) {
			return false;
		}
		r_out = Rect2i(int(x), int(y), int(w), int(h));
		return true;
	}
	if (p_value.get_type() == Variant::DICTIONARY) {
		Dictionary dict = p_value;
		int64_t x = 0;
		int64_t y = 0;
		int64_t w = 0;
		int64_t h = 0;
		if (!_dict_get_int(dict, "x", x) || !_dict_get_int(dict, "y", y)) {
			return false;
		}
		if (!_dict_get_int(dict, "w", w)) {
			if (!_dict_get_int(dict, "width", w)) {
				return false;
			}
		}
		if (!_dict_get_int(dict, "h", h)) {
			if (!_dict_get_int(dict, "height", h)) {
				return false;
			}
		}
		r_out = Rect2i(int(x), int(y), int(w), int(h));
		return true;
	}
	return false;
}

static Variant _coerce_variant_for_type(const Variant &p_value, Variant::Type p_target_type) {
	if (p_value.get_type() == p_target_type) {
		return p_value;
	}
	switch (p_target_type) {
		case Variant::VECTOR2: {
			Vector2 out;
			if (_coerce_vector2(p_value, out)) {
				return out;
			}
		} break;
		case Variant::VECTOR2I: {
			Vector2i out;
			if (_coerce_vector2i(p_value, out)) {
				return out;
			}
		} break;
		case Variant::VECTOR3: {
			Vector3 out;
			if (_coerce_vector3(p_value, out)) {
				return out;
			}
		} break;
		case Variant::VECTOR3I: {
			Vector3i out;
			if (_coerce_vector3i(p_value, out)) {
				return out;
			}
		} break;
		case Variant::VECTOR4: {
			Vector4 out;
			if (_coerce_vector4(p_value, out)) {
				return out;
			}
		} break;
		case Variant::VECTOR4I: {
			Vector4i out;
			if (_coerce_vector4i(p_value, out)) {
				return out;
			}
		} break;
		case Variant::COLOR: {
			Color out;
			if (_coerce_color(p_value, out)) {
				return out;
			}
		} break;
		case Variant::RECT2: {
			Rect2 out;
			if (_coerce_rect2(p_value, out)) {
				return out;
			}
		} break;
		case Variant::RECT2I: {
			Rect2i out;
			if (_coerce_rect2i(p_value, out)) {
				return out;
			}
		} break;
		default:
			break;
	}
	return p_value;
}

AutomationServer *AutomationServer::singleton = nullptr;

AutomationServer *AutomationServer::get_singleton() {
	return singleton;
}

AutomationServer::AutomationServer() {
	singleton = this;
}

AutomationServer::~AutomationServer() {
	stop();
	singleton = nullptr;
}

bool AutomationServer::start(const String &p_host, int p_port, const String &p_token) {
	if (active) {
		return true;
	}
	if (p_port <= 0) {
		return false;
	}
	server.instantiate();
	Error err = server->listen(p_port, p_host.is_empty() ? String("127.0.0.1") : p_host);
	if (err != OK) {
		server.unref();
		return false;
	}
	token = p_token;
	active = true;
	return true;
}

void AutomationServer::stop() {
	if (!active) {
		return;
	}
	for (int i = 0; i < clients.size(); i++) {
		if (clients[i].peer.is_valid()) {
			clients[i].peer->disconnect_from_host();
		}
	}
	clients.clear();
	if (server.is_valid()) {
		server->stop();
		server.unref();
	}
	active = false;
	token = "";
}

void AutomationServer::poll() {
	if (!active) {
		return;
	}
	_accept_clients();
	for (int i = clients.size() - 1; i >= 0; i--) {
		_poll_client(i);
	}
}

void AutomationServer::_accept_clients() {
	if (!server.is_valid()) {
		return;
	}
	while (server->is_connection_available()) {
		Ref<StreamPeerTCP> peer = server->take_connection();
		if (peer.is_null()) {
			continue;
		}
		ClientState client;
		client.peer = peer;
		client.authed = token.is_empty();
		clients.push_back(client);
	}
}

void AutomationServer::_poll_client(int p_index) {
	if (p_index < 0 || p_index >= clients.size()) {
		return;
	}
	ClientState &client = clients.write[p_index];
	if (client.peer.is_null() || client.peer->get_status() != StreamPeerTCP::STATUS_CONNECTED) {
		_drop_client(p_index);
		return;
	}
	int available = client.peer->get_available_bytes();
	if (available > 0) {
		Vector<uint8_t> data;
		data.resize(available);
		Error err = client.peer->get_data(data.ptrw(), available);
		if (err == OK) {
			client.buffer += String::utf8(reinterpret_cast<const char *>(data.ptr()), available);
		}
	}
	int newline = client.buffer.find("\n");
	while (newline >= 0) {
		String line = client.buffer.substr(0, newline).strip_edges();
		client.buffer = client.buffer.substr(newline + 1);
		if (!line.is_empty()) {
			Ref<JSON> json;
			json.instantiate();
			Error err = json->parse(line);
			Dictionary response;
			if (err != OK) {
				response = _make_error(-1, vformat("parse_error:%s", json->get_error_message()));
			} else {
				Variant data = json->get_data();
				if (data.get_type() != Variant::DICTIONARY) {
					response = _make_error(-1, "invalid_request");
				} else {
					response = _handle_request(data, client);
				}
			}
			String payload = JSON::stringify(response, "");
			payload += "\n";
			CharString utf8 = payload.utf8();
			client.peer->put_data(reinterpret_cast<const uint8_t *>(utf8.get_data()), utf8.length());
		}
		newline = client.buffer.find("\n");
	}
}

void AutomationServer::_drop_client(int p_index) {
	if (p_index < 0 || p_index >= clients.size()) {
		return;
	}
	if (clients[p_index].peer.is_valid()) {
		clients[p_index].peer->disconnect_from_host();
	}
	clients.remove_at(p_index);
}

Dictionary AutomationServer::_handle_request(const Dictionary &p_request, ClientState &r_client) {
	int id = -1;
	if (p_request.has("id") && p_request["id"].get_type() == Variant::INT) {
		id = int(p_request["id"]);
	}
	String method = p_request.get("method", "");
	Dictionary params = p_request.get("params", Dictionary());

	if (!r_client.authed) {
		if (method != "auth") {
			return _make_error(id, "unauthorized");
		}
		String provided = params.get("token", "");
		if (provided != token) {
			return _make_error(id, "auth_failed");
		}
		r_client.authed = true;
		return _make_ok(id, "authed");
	}

	if (method == "ping") {
		return _make_ok(id, "pong");
	}
	if (method == "get_node") {
		Node *node = _resolve_node(params);
		if (!node) {
			return _make_error(id, "node_not_found");
		}
		Dictionary result;
		result["id"] = int64_t(node->get_instance_id());
		result["name"] = node->get_name();
		result["class"] = node->get_class();
		result["path"] = String(node->get_path());
		return _make_ok(id, result);
	}
	if (method == "list_children") {
		Node *node = _resolve_node(params);
		if (!node) {
			return _make_error(id, "node_not_found");
		}
		Array children;
		for (int i = 0; i < node->get_child_count(); i++) {
			Node *child = node->get_child(i);
			if (!child) {
				continue;
			}
			Dictionary item;
			item["id"] = int64_t(child->get_instance_id());
			item["name"] = child->get_name();
			item["class"] = child->get_class();
			item["path"] = String(child->get_path());
			children.push_back(item);
		}
		return _make_ok(id, children);
	}
	if (method == "dump_node_tree") {
		Node *node = _resolve_node(params);
		if (!node) {
			return _make_error(id, "node_not_found");
		}
		int max_depth = params.get("max_depth", 3);
		int max_children = params.get("max_children", 64);
		Dictionary result = _dump_node(node, 0, max_depth, max_children);
		return _make_ok(id, result);
	}
	if (method == "call") {
		Object *target = _resolve_target(params);
		if (!target) {
			return _make_error(id, "target_not_found");
		}
		StringName method_name = params.get("method", "");
		Array args = params.get("args", Array());
		if (!args.is_empty()) {
			List<MethodInfo> methods;
			target->get_method_list(&methods);
			MethodInfo method_info;
			bool has_method_info = false;
			String method_name_str = String(method_name);
			for (const MethodInfo &info : methods) {
				if (info.name == method_name_str) {
					method_info = info;
					has_method_info = true;
					break;
				}
			}
			if (has_method_info && !(method_info.flags & METHOD_FLAG_VARARG)) {
				int arg_count = MIN(args.size(), method_info.arguments.size());
				for (int i = 0; i < arg_count; i++) {
					Variant::Type expected_type = method_info.arguments[i].type;
					args[i] = _coerce_variant_for_type(args[i], expected_type);
				}
			}
		}
		Variant result = target->callv(method_name, args);
		return _make_ok(id, _sanitize(result));
	}
	if (method == "get_surface_shader_param") {
		Node *node = _resolve_node(params);
		if (!node) {
			return _make_error(id, "node_not_found");
		}
		MeshInstance3D *mesh = Object::cast_to<MeshInstance3D>(node);
		if (!mesh) {
			return _make_error(id, "not_mesh_instance");
		}
		int surface = params.get("surface", 0);
		StringName param = params.get("param", "");
		if (param == StringName()) {
			return _make_error(id, "missing_param");
		}
		Ref<Material> material = mesh->get_surface_override_material(surface);
		Ref<ShaderMaterial> shader_material = material;
		if (shader_material.is_null()) {
			return _make_error(id, "no_shader_material");
		}
		Variant result = shader_material->get_shader_parameter(param);
		return _make_ok(id, _sanitize(result));
	}
	if (method == "set_surface_shader_param") {
		Node *node = _resolve_node(params);
		if (!node) {
			return _make_error(id, "node_not_found");
		}
		MeshInstance3D *mesh = Object::cast_to<MeshInstance3D>(node);
		if (!mesh) {
			return _make_error(id, "not_mesh_instance");
		}
		int surface = params.get("surface", 0);
		StringName param = params.get("param", "");
		if (param == StringName()) {
			return _make_error(id, "missing_param");
		}
		if (!params.has("value")) {
			return _make_error(id, "missing_value");
		}
		Ref<Material> material = mesh->get_surface_override_material(surface);
		Ref<ShaderMaterial> shader_material = material;
		if (shader_material.is_null()) {
			return _make_error(id, "no_shader_material");
		}
		shader_material->set_shader_parameter(param, params["value"]);
		return _make_ok(id, true);
	}
	if (method == "get_surface_material") {
		Node *node = _resolve_node(params);
		if (!node) {
			return _make_error(id, "node_not_found");
		}
		MeshInstance3D *mesh = Object::cast_to<MeshInstance3D>(node);
		if (!mesh) {
			return _make_error(id, "not_mesh_instance");
		}
		int surface = params.get("surface", 0);
		Ref<Material> material = mesh->get_surface_override_material(surface);
		if (material.is_null()) {
			return _make_error(id, "no_material");
		}
		Dictionary info;
		info["class"] = material->get_class();
		info["id"] = int64_t(material->get_instance_id());
		info["id_u64"] = String::num_uint64(material->get_instance_id());
		return _make_ok(id, info);
	}
	if (method == "get_shader_param") {
		Object *target = _resolve_target(params);
		if (!target) {
			return _make_error(id, "target_not_found");
		}
		ShaderMaterial *material = Object::cast_to<ShaderMaterial>(target);
		if (!material) {
			return _make_error(id, "not_shader_material");
		}
		StringName param = params.get("param", "");
		if (param == StringName()) {
			return _make_error(id, "missing_param");
		}
		Variant result = material->get_shader_parameter(param);
		return _make_ok(id, _sanitize(result));
	}
	if (method == "set_shader_param") {
		Object *target = _resolve_target(params);
		if (!target) {
			return _make_error(id, "target_not_found");
		}
		ShaderMaterial *material = Object::cast_to<ShaderMaterial>(target);
		if (!material) {
			return _make_error(id, "not_shader_material");
		}
		StringName param = params.get("param", "");
		if (param == StringName()) {
			return _make_error(id, "missing_param");
		}
		if (!params.has("value")) {
			return _make_error(id, "missing_value");
		}
		material->set_shader_parameter(param, params["value"]);
		return _make_ok(id, true);
	}
	if (method == "get") {
		Object *target = _resolve_target(params);
		if (!target) {
			return _make_error(id, "target_not_found");
		}
		StringName prop = params.get("property", "");
		Variant result = target->get(prop);
		return _make_ok(id, _sanitize(result));
	}
	if (method == "set") {
		Object *target = _resolve_target(params);
		if (!target) {
			return _make_error(id, "target_not_found");
		}
		StringName prop = params.get("property", "");
		if (!params.has("value")) {
			return _make_error(id, "missing_value");
		}
		Variant value = params["value"];
		List<PropertyInfo> props;
		target->get_property_list(&props);
		for (const PropertyInfo &info : props) {
			if (info.name == prop) {
				value = _coerce_variant_for_type(value, info.type);
				break;
			}
		}
		target->set(prop, value);
		return _make_ok(id, true);
	}
	if (method == "action_press") {
		StringName action = params.get("action", "");
		double strength = params.get("strength", 1.0);
		Input::get_singleton()->action_press(action, strength);
		return _make_ok(id, true);
	}
	if (method == "action_release") {
		StringName action = params.get("action", "");
		Input::get_singleton()->action_release(action);
		return _make_ok(id, true);
	}
	if (method == "screenshot") {
		String path = params.get("path", "user://automation_frame.png");
		SceneTree *tree = SceneTree::get_singleton();
		if (!tree) {
			return _make_error(id, "no_scene_tree");
		}
		Window *root = tree->get_root();
		if (!root || root->get_texture().is_null()) {
			return _make_error(id, "no_viewport");
		}
		Ref<Image> image = root->get_texture()->get_image();
		if (image.is_null()) {
			return _make_error(id, "no_image");
		}
		Error err = image->save_png(path);
		if (err != OK) {
			return _make_error(id, "save_failed");
		}
		return _make_ok(id, path);
	}
	if (method == "get_fps") {
		return _make_ok(id, Engine::get_singleton()->get_frames_per_second());
	}
	if (method == "rd_stats") {
		RenderingDevice *rd = RenderingServer::get_singleton()->get_rendering_device();
		Dictionary stats;
		stats["video_adapter"] = RenderingServer::get_singleton()->get_video_adapter_name();
		stats["video_adapter_type"] = RenderingServer::get_singleton()->get_video_adapter_type();
		stats["driver_report"] = rd ? rd->get_driver_and_device_memory_report() : String();
		stats["rd_available"] = rd != nullptr;
		return _make_ok(id, stats);
	}
	if (method == "quit") {
		SceneTree *tree = SceneTree::get_singleton();
		if (tree) {
			tree->quit();
		}
		return _make_ok(id, true);
	}

	return _make_error(id, "unknown_method");
}

Variant AutomationServer::_sanitize(const Variant &p_value) const {
	switch (p_value.get_type()) {
		case Variant::NIL:
		case Variant::BOOL:
		case Variant::INT:
		case Variant::FLOAT:
		case Variant::STRING:
			return p_value;
		case Variant::ARRAY: {
			Array out;
			Array in = p_value;
			out.resize(in.size());
			for (int i = 0; i < in.size(); i++) {
				out[i] = _sanitize(in[i]);
			}
			return out;
		}
		case Variant::DICTIONARY: {
			Dictionary out;
			Dictionary in = p_value;
			Array keys = in.keys();
			for (int i = 0; i < keys.size(); i++) {
				Variant key = keys[i];
				out[key.stringify()] = _sanitize(in[key]);
			}
			return out;
		}
		case Variant::OBJECT: {
			Object *obj = p_value;
			if (!obj) {
				return Variant();
			}
			Dictionary info;
			info["id"] = int64_t(obj->get_instance_id());
			info["id_u64"] = String::num_uint64(obj->get_instance_id());
			info["class"] = obj->get_class();
			return info;
		}
		default:
			return p_value.stringify();
	}
}

Dictionary AutomationServer::_make_error(int p_id, const String &p_message) const {
	Dictionary result;
	result["id"] = p_id;
	result["ok"] = false;
	result["error"] = p_message;
	return result;
}

Dictionary AutomationServer::_make_ok(int p_id, const Variant &p_result) const {
	Dictionary result;
	result["id"] = p_id;
	result["ok"] = true;
	result["result"] = _sanitize(p_result);
	return result;
}

Object *AutomationServer::_resolve_target(const Dictionary &p_params) const {
	if (p_params.has("id_u64")) {
		Variant raw = p_params["id_u64"];
		if (raw.get_type() == Variant::STRING) {
			int64_t parsed = String(raw).to_int();
			if (parsed >= 0) {
				uint64_t oid = uint64_t(parsed);
				Object *obj = ObjectDB::get_instance(ObjectID(oid));
				if (obj) {
					return obj;
				}
			}
		}
	}
	if (p_params.has("id")) {
		ObjectID oid = ObjectID(int64_t(p_params["id"]));
		Object *obj = ObjectDB::get_instance(oid);
		if (obj) {
			return obj;
		}
	}
	Node *node = _resolve_node(p_params);
	return node;
}

Node *AutomationServer::_resolve_node(const Dictionary &p_params) const {
	SceneTree *tree = SceneTree::get_singleton();
	if (!tree) {
		return nullptr;
	}
	Window *root = tree->get_root();
	if (!root) {
		return nullptr;
	}
	if (!p_params.has("path")) {
		return root;
	}
	String path = p_params["path"];
	if (path.is_empty() || path == "/") {
		return root;
	}
	NodePath node_path(path);
	Node *node = root->get_node_or_null(node_path);
	return node;
}

Dictionary AutomationServer::_dump_node(Node *p_node, int p_depth, int p_max_depth, int p_max_children) const {
	Dictionary result;
	if (!p_node) {
		return result;
	}
	result["id"] = int64_t(p_node->get_instance_id());
	result["name"] = p_node->get_name();
	result["class"] = p_node->get_class();
	result["path"] = String(p_node->get_path());
	result["depth"] = p_depth;

	if (p_depth >= p_max_depth) {
		return result;
	}

	Array children;
	int child_count = p_node->get_child_count();
	int limit = MIN(child_count, p_max_children);
	for (int i = 0; i < limit; i++) {
		Node *child = p_node->get_child(i);
		if (!child) {
			continue;
		}
		children.push_back(_dump_node(child, p_depth + 1, p_max_depth, p_max_children));
	}
	result["children"] = children;
	result["child_count"] = child_count;
	return result;
}
