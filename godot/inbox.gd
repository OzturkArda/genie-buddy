extends Node
## The genie's ears: a small HTTP server on 127.0.0.1 that speaks three dialects.
##   /poke, /heartbeat, /answer/<id>, /status   plain JSON, for scripts and curl
##   /mcp                                       MCP over Streamable HTTP, for any MCP client
##   /hook/claude, /hook/codex                  raw hook events from Claude Code and Codex
## It turns all of them into calls on the genie (main.gd).

const VERSION := "0.2.2"
const LONG_TURN := 60.0  # a Claude Code turn at least this long earns a "finished" poke
const MCP_INSTRUCTIONS := "Genie Buddy is a character on the user's desktop. Call poke to tell the user something they should not miss while away from the terminal (a long job finished, a blocker, a question), and heartbeat while watching a long-running job so the genie notices if you go silent."
const MCP_TOOLS := [
	{"name": "poke", "description": "Make the genie come out of its lamp and tell the user something. Blockers and questions chase the user's cursor until answered; info and progress show briefly. With options, the user's clicked label comes back as the answer.",
	 "inputSchema": {"type": "object", "required": ["title"], "properties": {
		"title": {"type": "string", "description": "One line the user reads first."},
		"body": {"type": "string", "description": "Optional short detail."},
		"kind": {"type": "string", "enum": ["info", "progress", "done", "question", "blocker"]},
		"options": {"type": "array", "items": {"type": "string"}, "description": "Button labels, e.g. [\"Retry\", \"Leave it\"]."},
		"agent": {"type": "string", "description": "Your session or task name, shown to the user."},
		"wait_seconds": {"type": "number", "description": "Block up to this long for the user's click. 0 returns the poke id at once; check later with get_answer."}}}},
	{"name": "get_answer", "description": "Status of a poke: pending, answered (with the clicked option) or seen.",
	 "inputSchema": {"type": "object", "required": ["poke_id"], "properties": {"poke_id": {"type": "integer"}}}},
	{"name": "heartbeat", "description": "Tell the genie a watched job is alive. If no heartbeat arrives within about twice every_s, the genie warns the user that the job has gone quiet. Send state finished or failed to stop watching (poke separately for the news).",
	 "inputSchema": {"type": "object", "required": ["job"], "properties": {
		"job": {"type": "string", "description": "Stable name of the job, e.g. \"nightly build #1234\"."},
		"detail": {"type": "string", "description": "Short progress line, e.g. \"41/60 jobs\"."},
		"every_s": {"type": "number", "description": "Seconds until your next heartbeat."},
		"state": {"type": "string", "enum": ["running", "finished", "failed"]},
		"agent": {"type": "string", "description": "Your session or task name."}}}},
]
const REASONS := {200: "OK", 202: "Accepted", 204: "No Content", 400: "Bad Request", 403: "Forbidden",
		404: "Not Found", 405: "Method Not Allowed"}

var genie: Node
var server := TCPServer.new()
var conns := []          # open requests still arriving: {peer, buf, t, continued}
var waiting := []        # MCP pokes holding their response until the user clicks: {peer, rpc_id, item_id, deadline}
var mcp_clients := {}    # Mcp-Session-Id -> client name
var turn_started := {}   # Claude Code session id -> when the current prompt was submitted
var session_names := {}  # Claude Code session id -> the session's name, once found


func _init(owner_genie: Node) -> void:
	genie = owner_genie


func listen(port: int) -> int:
	return server.listen(port, "127.0.0.1")


func poll() -> void:
	while server.is_listening() and server.is_connection_available():
		conns.append({"peer": server.take_connection(), "buf": PackedByteArray(), "t": genie.now, "continued": false})
	for c in conns.duplicate():
		var peer: StreamPeerTCP = c.peer
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED or genie.now - c.t > 10.0:
			conns.erase(c)
			continue
		var n := peer.get_available_bytes()
		if n > 0:
			var got: Array = peer.get_partial_data(n)
			if got[0] == OK:
				var buf: PackedByteArray = c.buf
				buf.append_array(got[1])
				c.buf = buf
		var req = _parse(c)
		if req != null:
			conns.erase(c)
			_handle(peer, req)
	for w in waiting.duplicate():
		var peer: StreamPeerTCP = w.peer
		peer.poll()
		var it = genie.item_by_id(w.item_id)
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			waiting.erase(w)
		elif it.status != "pending" or genie.now > w.deadline:
			var res := _answer_of(it)
			if it.status == "pending":
				res["timed_out"] = true
			_respond(peer, 200, _rpc_result(w.rpc_id, _tool_text(res)))
			waiting.erase(w)


# --- HTTP -------------------------------------------------------------------------

func _parse(c: Dictionary):
	var buf: PackedByteArray = c.buf
	var sep := -1
	for i in range(buf.size() - 3):
		if buf[i] == 13 and buf[i + 1] == 10 and buf[i + 2] == 13 and buf[i + 3] == 10:
			sep = i
			break
	if sep < 0:
		return null
	var lines := buf.slice(0, sep).get_string_from_utf8().split("\r\n")
	var first := lines[0].split(" ")
	var headers := {}
	for i in range(1, lines.size()):
		var kv := lines[i].split(":", true, 1)
		if kv.size() == 2:
			headers[kv[0].strip_edges().to_lower()] = kv[1].strip_edges()
	var length := str(headers.get("content-length", "0")).to_int()
	var body_bytes := buf.slice(sep + 4)
	if body_bytes.size() < length:
		if not c.continued and str(headers.get("expect", "")).to_lower() == "100-continue":
			c.continued = true
			c.peer.put_data("HTTP/1.1 100 Continue\r\n\r\n".to_utf8_buffer())
		return null
	var body = null
	if length > 0:
		var json := JSON.new()
		if json.parse(body_bytes.slice(0, length).get_string_from_utf8()) == OK:
			body = json.data
	return {"method": first[0], "path": (first[1] if first.size() > 1 else "").split("?")[0],
			"headers": headers, "body": body}


func _handle(peer: StreamPeerTCP, req: Dictionary) -> void:
	# Browsers may only reach the genie from a local page; this blocks drive-by pokes and DNS rebinding.
	var origin := str(req.headers.get("origin", ""))
	if origin != "" and not (origin.begins_with("http://127.0.0.1") or origin.begins_with("http://localhost")):
		_respond(peer, 403, {"error": "forbidden origin"})
		return
	var path: String = req.path
	var b = req.body
	if path == "/mcp":
		_handle_mcp(peer, req)
	elif req.method == "POST" and path.begins_with("/hook/"):
		_handle_hook(path.get_slice("/", 2), b if typeof(b) == TYPE_DICTIONARY else {})
		_respond(peer, 204, null)
	elif req.method == "POST" and path == "/poke":
		if typeof(b) != TYPE_DICTIONARY or str(b.get("title", "")).strip_edges() == "":
			_respond(peer, 400, {"error": "title is required"})
		else:
			_respond(peer, 200, {"id": genie.add_item(b).id})
	elif req.method == "POST" and path == "/heartbeat":
		var res := _heartbeat(b if typeof(b) == TYPE_DICTIONARY else {})
		_respond(peer, 400 if res.has("error") else 200, res)
	elif req.method == "GET" and path.begins_with("/answer/"):
		var it = genie.item_by_id(path.get_slice("/", 2).to_int())
		_respond(peer, 200 if it != null else 404, _answer_of(it) if it != null else {"error": "no such poke"})
	elif req.method == "GET" and path == "/status":
		_respond(peer, 200, genie.status())
	else:
		_respond(peer, 404, {"error": "not found"})


func _respond(peer: StreamPeerTCP, code: int, data, extra := {}) -> void:
	var body := PackedByteArray() if data == null else JSON.stringify(data).to_utf8_buffer()
	var head := "HTTP/1.1 %d %s\r\nContent-Length: %d\r\nConnection: close\r\n" % [code, REASONS.get(code, "OK"), body.size()]
	if data != null:
		head += "Content-Type: application/json\r\n"
	for k in extra:
		head += "%s: %s\r\n" % [k, extra[k]]
	peer.put_data((head + "\r\n").to_utf8_buffer())
	if body.size() > 0:
		peer.put_data(body)
	peer.disconnect_from_host()


func _heartbeat(b: Dictionary) -> Dictionary:
	var job := str(b.get("job", "")).strip_edges()
	if job == "":
		return {"error": "job is required"}
	return {"ok": true, "watching": genie.heartbeat(job, str(b.get("agent", "an agent")), str(b.get("detail", "")),
			float(b.get("every_s", 300)), str(b.get("state", "running")))}


func _answer_of(it) -> Dictionary:
	if it == null:
		return {"error": "no such poke"}
	return {"id": it.id, "status": it.status, "answer": it.answer}


# --- MCP (Streamable HTTP, JSON responses) -----------------------------------------

func _handle_mcp(peer: StreamPeerTCP, req: Dictionary) -> void:
	if req.method != "POST":
		_respond(peer, 405, {"error": "POST JSON-RPC messages here; there is no event stream"}, {"Allow": "POST"})
		return
	var msg = req.body
	if typeof(msg) != TYPE_DICTIONARY:
		_respond(peer, 400, _rpc_error(null, -32700, "expected one JSON-RPC message"))
		return
	if not msg.has("id"):
		_respond(peer, 202, null)  # a notification, e.g. notifications/initialized
		return
	var id = msg.id
	var params: Dictionary = msg.params if typeof(msg.get("params")) == TYPE_DICTIONARY else {}
	match str(msg.get("method", "")):
		"initialize":
			var sid := "%08x%08x" % [randi(), Time.get_ticks_usec() & 0xffffffff]
			var info = params.get("clientInfo", {})
			mcp_clients[sid] = str(info.get("name", "an agent")) if typeof(info) == TYPE_DICTIONARY else "an agent"
			_respond(peer, 200, _rpc_result(id, {"protocolVersion": str(params.get("protocolVersion", "2025-06-18")),
					"capabilities": {"tools": {}}, "serverInfo": {"name": "genie-buddy", "version": VERSION},
					"instructions": MCP_INSTRUCTIONS}), {"Mcp-Session-Id": sid})
		"ping":
			_respond(peer, 200, _rpc_result(id, {}))
		"tools/list":
			_respond(peer, 200, _rpc_result(id, {"tools": MCP_TOOLS}))
		"tools/call":
			_mcp_call(peer, id, params, str(req.headers.get("mcp-session-id", "")))
		_:
			_respond(peer, 200, _rpc_error(id, -32601, "method not found"))


func _mcp_call(peer: StreamPeerTCP, id, params: Dictionary, sid: String) -> void:
	var args: Dictionary = params.arguments.duplicate() if typeof(params.get("arguments")) == TYPE_DICTIONARY else {}
	if str(args.get("agent", "")).strip_edges() == "":
		args["agent"] = mcp_clients.get(sid, "an agent")
	match str(params.get("name", "")):
		"poke":
			if str(args.get("title", "")).strip_edges() == "":
				_respond(peer, 200, _rpc_result(id, _tool_text({"error": "title is required"}, true)))
				return
			var it: Dictionary = genie.add_item(args)
			var wait := float(args.get("wait_seconds", 0))
			if wait > 0.0:
				waiting.append({"peer": peer, "rpc_id": id, "item_id": it.id, "deadline": genie.now + wait})
			else:
				_respond(peer, 200, _rpc_result(id, _tool_text(_answer_of(it))))
		"get_answer":
			var res := _answer_of(genie.item_by_id(int(args.get("poke_id", 0))))
			_respond(peer, 200, _rpc_result(id, _tool_text(res, res.has("error"))))
		"heartbeat":
			var res := _heartbeat(args)
			_respond(peer, 200, _rpc_result(id, _tool_text(res, res.has("error"))))
		_:
			_respond(peer, 200, _rpc_error(id, -32602, "unknown tool"))


func _rpc_result(id, result: Dictionary) -> Dictionary:
	return {"jsonrpc": "2.0", "id": _rpc_id(id), "result": result}


func _rpc_error(id, code: int, message: String) -> Dictionary:
	return {"jsonrpc": "2.0", "id": _rpc_id(id), "error": {"code": code, "message": message}}


func _rpc_id(id):
	# Godot parses every JSON number as a float; echo integral ids back as integers.
	return int(id) if typeof(id) == TYPE_FLOAT and id == floorf(id) else id


func _tool_text(data: Dictionary, is_error := false) -> Dictionary:
	return {"content": [{"type": "text", "text": JSON.stringify(data)}], "isError": is_error}


# --- hooks -------------------------------------------------------------------------

func _handle_hook(source: String, b: Dictionary) -> void:
	var cwd := str(b.get("cwd", "")).replace("\\", "/").trim_suffix("/")
	var project := cwd.get_file() if cwd != "" else source
	match source:
		"claude":
			var sid := str(b.get("session_id", ""))
			var event := str(b.get("hook_event_name", ""))
			if event == "Stop" or event == "Notification":
				var name := _session_name(sid, str(b.get("transcript_path", "")))
				if name != "":
					project = name
			match event:
				"UserPromptSubmit":
					turn_started[sid] = genie.now
				"Stop":
					var started: float = turn_started.get(sid, -1.0)
					turn_started.erase(sid)
					if started >= 0.0 and genie.now - started >= LONG_TURN:
						genie.add_item({"kind": "done", "agent": project, "title": "Finished after " + genie.ago(genie.now - started),
								"body": _last_assistant_text(str(b.get("transcript_path", "")))})
				"Notification":
					var message := str(b.get("message", "Claude Code needs you"))
					var idle := message.to_lower().contains("waiting for your input")
					genie.add_item({"kind": "info" if idle else "question", "agent": project, "title": message,
							"body": "" if idle else "Answer in the Claude Code terminal."})
		"codex":
			if str(b.get("type", "")) == "agent-turn-complete":
				genie.add_item({"kind": "info", "agent": "Codex · " + project, "title": "Codex finished its turn",
						"body": str(b.get("last-assistant-message", "")).strip_edges().left(400)})


# Claude Code records a session's name ("customTitle", or "agentName" for a background
# job) in its transcript. Prefer it to the folder name, which is often a generic launcher.
func _session_name(sid: String, path: String) -> String:
	var found := _latest_title(path, 262144)
	if found == "" and not session_names.has(sid):
		found = _latest_title(path, 0)  # not in the tail: scan the whole file, once
	if found != "":
		session_names[sid] = found
	return session_names.get(sid, "")


func _latest_title(path: String, tail: int) -> String:
	if path == "" or not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var size := f.get_length()
	f.seek(maxi(0, size - tail) if tail > 0 else 0)
	var lines := f.get_buffer(size - f.get_position()).get_string_from_utf8().split("\n", false)
	var json := JSON.new()
	for i in range(lines.size() - 1, -1, -1):
		if not (lines[i].contains("\"customTitle\"") or lines[i].contains("\"agentName\"")):
			continue
		if json.parse(lines[i]) != OK or typeof(json.data) != TYPE_DICTIONARY:
			continue
		var title := str(json.data.get("customTitle", json.data.get("agentName", ""))).strip_edges()
		if title != "":
			return title.left(60)
	return ""


func _last_assistant_text(path: String) -> String:
	if path == "" or not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var size := f.get_length()
	f.seek(maxi(0, size - 65536))
	var lines := f.get_buffer(size - f.get_position()).get_string_from_utf8().split("\n", false)
	var json := JSON.new()
	for i in range(lines.size() - 1, -1, -1):
		if json.parse(lines[i]) != OK or typeof(json.data) != TYPE_DICTIONARY or json.data.get("type") != "assistant":
			continue
		var msg = json.data.get("message", {})
		var content = msg.get("content", []) if typeof(msg) == TYPE_DICTIONARY else []
		if typeof(content) != TYPE_ARRAY:
			continue
		for part in content:
			if typeof(part) == TYPE_DICTIONARY and part.get("type") == "text" and str(part.get("text", "")).strip_edges() != "":
				return str(part.text).strip_edges().left(400)
	return ""
