extends SceneTree
# Cross-play matchmaking check against a real server, driven by
# tests/e2e/queue-e2e.mjs, which runs the auth endpoint and @hibira-io/lobby
# players. Not part of CI.
# Env: E2E_KEY, E2E_HOST, E2E_PORT, E2E_TLS, E2E_AUTH_URL, E2E_CHANNEL.

var client: HibiraClient
var queue: HibiraQueue
var room: HibiraRoom
var finished := false


func _initialize() -> void:
	client = HibiraClient.new()
	client.app_key = OS.get_environment("E2E_KEY")
	client.host = OS.get_environment("E2E_HOST")
	client.port = int(OS.get_environment("E2E_PORT"))
	client.use_tls = OS.get_environment("E2E_TLS") == "1"
	client.auth_endpoint = OS.get_environment("E2E_AUTH_URL")
	client.auth_params = {"user_id": "u-godot", "name": "Gina", "rating": 1000}
	root.add_child(client)
	queue = HibiraQueue.join(client, OS.get_environment("E2E_CHANNEL"), {"size": 2, "rating_range": 100, "timeout": 30})
	queue.joined.connect(func(u): print("JOINED host=%s" % u.host))
	queue.join_failed.connect(func(s, m): _done(1, "join failed %d %s" % [s, m]))
	queue.timed_out.connect(func(_w): _done(1, "timed out"))
	queue.matched.connect(_on_matched)
	client.connect_to_server()
	create_timer(40).timeout.connect(func(): _done(1, "no room in time"))


func _on_matched(found: Dictionary) -> void:
	print("MATCHED %s %s" % [found.channel, ",".join(found.players.map(func(p): return p.id))])
	room = found.room
	var check := func(players, _a = null, _b = null):
		if players.size() == 2:
			_done(0, "met %s" % ",".join(players.map(func(p): return p.id)))
	room.joined.connect(check)
	room.members_changed.connect(check)


func _done(code: int, msg: String) -> void:
	if finished:
		return
	finished = true
	print(("OK " if code == 0 else "FAIL ") + msg)
	await create_timer(1.0).timeout
	quit(code)
