extends SceneTree
# Offline tests for the Hibira addon: feeds Pusher protocol frames into a
# client whose socket is replaced by a list, and checks what it sends back.
#
#   godot --headless --import && godot --headless --script res://tests/test_protocol.gd

class FakeClient extends HibiraClient:
	var sent: Array = []

	func _send(message: Dictionary) -> bool:
		# Round-trip through JSON, as the wire does.
		sent.append(JSON.parse_string(JSON.stringify(message)))
		return true

	func frame(event: String, data: Variant, channel := "", user_id := "") -> void:
		var msg := {"event": event, "data": JSON.stringify(data)}
		if channel != "":
			msg.channel = channel
		if user_id != "":
			msg.user_id = user_id
		_handle_message(JSON.stringify(msg))

	func last(event: String) -> Variant:
		for i in range(sent.size() - 1, -1, -1):
			if sent[i].event == event:
				return sent[i]
		return null

var failures := 0
var checks := 0


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("FAIL: ", what)


func _initialize() -> void:
	await process_frame
	await test_connection()
	await test_presence_room()
	await test_room_full()
	print("%d checks, %d failed" % [checks, failures])
	quit(1 if failures > 0 else 0)


func new_client(user_id: String, joined_at: float) -> FakeClient:
	var c := FakeClient.new()
	c.app_key = "k"
	c.authorizer = func(socket_id: String, channel_name: String) -> Dictionary:
		return {"auth": "k:sig-%s-%s" % [socket_id, channel_name], "channel_data": JSON.stringify({"user_id": user_id, "user_info": {"name": user_id, "joined_at": joined_at}})}
	root.add_child(c)
	return c


func test_connection() -> void:
	var c := new_client("a", 1)
	var news := c.subscribe("news")
	var got := []
	news.bind("headline", func(data, _uid): got.append(data))
	c.frame("pusher:connection_established", {"socket_id": "1.2", "activity_timeout": 30})
	check(c.state == HibiraClient.State.CONNECTED, "connected")
	check(c.socket_id == "1.2", "socket id")
	var sub: Variant = c.last("pusher:subscribe")
	check(sub != null and sub.data.channel == "news" and not sub.data.has("auth"), "public subscribe without auth")
	c.frame("pusher_internal:subscription_succeeded", {}, "news")
	check(news.is_subscribed(), "subscribed")
	# Data triggered from a server is a JSON string; plain strings stay strings.
	c.frame("headline", {"title": "hi"}, "news")
	c._handle_message(JSON.stringify({"event": "headline", "channel": "news", "data": "plain text"}))
	check(got.size() == 2 and got[0] is Dictionary and got[0].title == "hi" and got[1] == "plain text", "event data decoded")
	c.frame("pusher:ping", {})
	check(c.last("pusher:pong") != null, "pong")
	check(not c.trigger("news", "client-x", {}), "no client events on public channels")
	var errors := []
	c.error.connect(func(code, message): errors.append([code, message]))
	c.frame("pusher:error", {"code": 4301, "message": "rate limited"})
	check(errors.size() == 1 and errors[0][0] == 4301, "pusher:error")
	c.unsubscribe("news")
	check(c.last("pusher:unsubscribe") != null and c.channel("news") == null, "unsubscribe")
	c.queue_free()


func test_presence_room() -> void:
	var c := new_client("b", 2000)
	var room := HibiraRoom.join(c, "presence-room-ABCD", {"capacity": 4})
	var events := {"joined": 0, "members": 0, "started": [], "messages": [], "host": [], "kicked": 0, "typing": []}
	room.joined.connect(func(_p, _h): events.joined += 1)
	room.members_changed.connect(func(_p, _j, _l): events.members += 1)
	room.started.connect(func(data, by): events.started.append([data, by]))
	room.message_received.connect(func(m): events.messages.append(m))
	room.host_changed.connect(func(h, prev): events.host.append([h.id, prev]))
	room.kicked.connect(func(_by, _r): events.kicked += 1)
	room.typing_changed.connect(func(t): events.typing.append(t))

	c.frame("pusher:connection_established", {"socket_id": "9.9", "activity_timeout": 120})
	await process_frame
	var sub: Variant = c.last("pusher:subscribe")
	check(sub != null and sub.data.auth == "k:sig-9.9-presence-room-ABCD", "presence subscribe is signed")
	check(sub != null and sub.data.has("channel_data"), "channel_data sent")
	check(room.my_id() == "b", "my id from channel_data")

	# "a" joined before us, so "a" is host.
	c.frame("pusher_internal:subscription_succeeded", {"presence": {
		"ids": ["a", "b"], "count": 2,
		"hash": {"a": {"name": "A", "joined_at": 1000}, "b": {"name": "B", "joined_at": 2000}},
	}}, "presence-room-ABCD")
	check(events.joined == 1 and room.is_joined, "joined")
	check(room.host().id == "a" and not room.is_host(), "earliest joiner is host")
	check(room.players().map(func(p): return p.id) == ["a", "b"], "seat order")

	room.set_ready(true)
	var ready: Variant = c.last("client-lobby-ready")
	check(ready != null and ready.channel == "presence-room-ABCD" and ready.data.ready == true, "ready sent")
	check(room.me().ready, "own ready applied locally")

	c.frame("client-lobby-ready", {"ready": true}, "presence-room-ABCD", "a")
	check(room.all_ready(), "all ready")

	# Only the host can start.
	c.frame("client-lobby-start", {"data": {"delays": [1]}, "seq": 1}, "presence-room-ABCD", "x")
	check(events.started.is_empty(), "start from a non-member ignored")
	c.frame("client-lobby-start", {"data": {"delays": [1500, 2000]}, "seq": 1}, "presence-room-ABCD", "a")
	check(events.started.size() == 1 and events.started[0][1] == "a" and events.started[0][0].delays.size() == 2, "start from host")
	check(room.phase == "started", "phase started")

	c.frame("client-lobby-typing", {}, "presence-room-ABCD", "a")
	check(room.typing() == ["a"], "typing")
	c.frame("client-lobby-chat", {"id": "m1", "text": "gl hf"}, "presence-room-ABCD", "a")
	check(events.messages.size() == 1 and events.messages[0].info.name == "A" and not events.messages[0].mine, "chat received")
	check(room.typing().is_empty(), "chat clears typing")
	var mine := room.send("hello")
	check(mine.mine and c.last("client-lobby-chat").data.text == "hello", "chat sent")

	# A later joiner: nobody's seat changes.
	c.frame("pusher_internal:member_added", {"user_id": "c", "user_info": {"name": "C", "joined_at": 3000}}, "presence-room-ABCD")
	check(room.players().size() == 3 and room.host().id == "a", "member added")

	# The host leaves: we are next in order and take over.
	c.frame("pusher_internal:member_removed", {"user_id": "a"}, "presence-room-ABCD")
	check(room.is_host() and events.host.size() == 1 and events.host[0] == ["b", "a"], "host hand-over")

	# As host, a new member gets a state snapshot shortly after joining.
	c.sent.clear()
	c.frame("pusher_internal:member_added", {"user_id": "d", "user_info": {"name": "D", "joined_at": 4000}}, "presence-room-ABCD")
	await create_timer(0.3).timeout
	var state: Variant = c.last("client-lobby-state")
	check(state != null and state.data.phase == "started" and state.data.ready.b == true, "host sends state to new member")

	room.set_settings({"rounds": 3})
	check(c.last("client-lobby-settings").data.settings.rounds == 3, "settings sent")

	# A kick from someone who is not the host is ignored.
	c.frame("client-lobby-kick", {"user_id": "b"}, "presence-room-ABCD", "c")
	check(events.kicked == 0, "kick from non-host ignored")
	c.queue_free()


func test_room_full() -> void:
	# Two players were authorized at the same moment; we joined last and the
	# room holds two.
	var c := new_client("z", 5000)
	var room := HibiraRoom.join(c, "presence-room-FULL", {"capacity": 2})
	var full := []
	room.full.connect(func(cap): full.append(cap))
	c.frame("pusher:connection_established", {"socket_id": "1.1"})
	await process_frame
	c.frame("pusher_internal:subscription_succeeded", {"presence": {
		"ids": ["x", "y", "z"], "count": 3,
		"hash": {"x": {"joined_at": 1}, "y": {"joined_at": 2}, "z": {"joined_at": 5000}},
	}}, "presence-room-FULL")
	check(full == [2], "full emitted for the member past capacity")
	check(c.last("pusher:unsubscribe") != null, "left the full room")

	var refused := []
	var c2 := FakeClient.new()
	c2.app_key = "k"
	c2.authorizer = func(_s, _n): return {"status": 403, "error": "room full"}
	root.add_child(c2)
	var room2 := HibiraRoom.join(c2, "presence-room-NOPE")
	room2.join_failed.connect(func(status, message): refused.append([status, message]))
	c2.frame("pusher:connection_established", {"socket_id": "2.2"})
	await process_frame
	check(refused == [[403, "room full"]], "auth refusal reaches join_failed")
	c.queue_free()
	c2.queue_free()
