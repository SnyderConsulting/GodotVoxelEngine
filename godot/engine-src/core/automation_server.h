#pragma once

#include "core/io/stream_peer_tcp.h"
#include "core/io/tcp_server.h"
#include "core/string/ustring.h"
#include "core/templates/vector.h"
#include "core/variant/variant.h"

class Node;
class Object;

class AutomationServer {
public:
	static AutomationServer *get_singleton();

	AutomationServer();
	~AutomationServer();

	bool start(const String &p_host, int p_port, const String &p_token);
	void stop();
	void poll();
	bool is_active() const { return active; }

private:
	struct ClientState {
		Ref<StreamPeerTCP> peer;
		String buffer;
		bool authed = false;
	};

	static AutomationServer *singleton;
	bool active = false;
	String token;
	Ref<TCPServer> server;
	Vector<ClientState> clients;

	void _accept_clients();
	void _poll_client(int p_index);
	void _drop_client(int p_index);

	Dictionary _handle_request(const Dictionary &p_request, ClientState &r_client);
	Variant _sanitize(const Variant &p_value) const;
	Dictionary _make_error(int p_id, const String &p_message) const;
	Dictionary _make_ok(int p_id, const Variant &p_result) const;
	Object *_resolve_target(const Dictionary &p_params) const;
	Node *_resolve_node(const Dictionary &p_params) const;
	Dictionary _dump_node(Node *p_node, int p_depth, int p_max_depth, int p_max_children) const;
};
