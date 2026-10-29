extends SceneTree
# Offline tests for HibiraSync and HibiraSyncHub, with the same fake socket as
# test_protocol.gd.
#
#   godot --headless --import && godot --headless --script res://tests/test_sync.gd

const FakeClient := preload("res://tests/fake_client.gd")

var failures := 0
var checks := 0


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("FAIL: ", what)


func _initialize() -> void:
	await process_frame
	test_values()
	await test_sync()
	print("%d checks, %d failed" % [checks, failures])
	quit(1 if failures > 0 else 0)


func roundtrip(v: Variant) -> Variant:
	return HibiraSync.decode(JSON.parse_string(JSON.stringify(HibiraSync.encode(v))))


func test_values() -> void:
	check(roundtrip(Vector2(1.5, -2)) == Vector2(1.5, -2), "Vector2")
	check(roundtrip(Vector3(1, 2, 3)) == Vector3(1, 2, 3), "Vector3")
	check(roundtrip(Vector2i(4, 5)) == Vector2i(4, 5), "Vector2i")
	check(roundtrip(Color(0.5, 0.25, 1, 0.5)).is_equal_approx(Color(0.5, 0.25, 1, 0.5)), "Color")
	check(roundtrip(Quaternion(0, 0, 0, 1)).is_equal_approx(Quaternion(0, 0, 0, 1)), "Quaternion")
	check(roundtrip(true) == true and roundtrip("hi") == "hi" and is_equal_approx(roundtrip(0.125), 0.125), "plain values")
	check(roundtrip({"a": Vector2(1, 2), "b": [Vector2(3, 4), 5]}) == {"a": Vector2(1, 2), "b": [Vector2(3, 4), 5.0]}, "nested")
	# A plain array whose first item is a tag stays an array.
	check(roundtrip(["V2", 1, 2]) == ["V2", 1.0, 2.0], "arrays are not mistaken for vectors")
	# Nothing a peer sends can become an object.
	check(HibiraSync.decode(["Object", "Node"]) == ["Object", "Node"], "no objects")


func test_sync() -> void:
	var c := FakeClient.new()
	c.name = "C"
	c.app_key = "k"
	c.authorizer = func(_s, _n): return {"auth": "k:x", "channel_data": JSON.stringify({"user_id": "me", "user_info": {}})}
	root.add_child(c)

	var local := Node2D.new()
	local.name = "Local"
	local.position = Vector2(10, 20)
	var mine := HibiraSync.new()
	mine.channel_name = "presence-play"
	mine.client_path = c.get_path()
	local.add_child(mine)
	root.add_child(local)

	var remote := Node2D.new()
	remote.name = "Remote"
	var theirs := HibiraSync.new()
	theirs.channel_name = "presence-play"
	theirs.owner_id = "bob"
	theirs.interpolate = false
	theirs.properties = PackedStringArray(["position", "modulate"])
	theirs.client_path = c.get_path()
	remote.add_child(theirs)
	root.add_child(remote)
	var left := []
	theirs.owner_left.connect(func(): left.append(true))

	c.frame("pusher:connection_established", {"socket_id": "1.1"})
	await process_frame
	check(c.last("pusher:subscribe") != null and c.last("pusher:subscribe").data.channel == "presence-play", "HibiraSync subscribes its channel")
	c.frame("pusher_internal:subscription_succeeded", {"presence": {"ids": ["me", "bob"], "count": 2, "hash": {"me": {}, "bob": {}}}}, "presence-play")
	check(mine.is_owner() and not theirs.is_owner(), "ownership")
	check(mine.key() == "me/Local" and theirs.key() == "bob/Remote", "default keys")

	var hub := HibiraSyncHub.of(c)
	c.sent.clear()
	hub.flush()
	var ev: Variant = c.last(HibiraSync.EVENT)
	check(ev != null and ev.channel == "presence-play", "sends a sync event")
	check(ev != null and ev.data.s.keys() == ["me/Local"], "only owned nodes are sent")
	check(ev != null and HibiraSync.decode(ev.data.s["me/Local"].position) == Vector2(10, 20), "position value")

	c.sent.clear()
	hub.flush()
	check(c.last(HibiraSync.EVENT) == null, "nothing sent when nothing changed")
	local.position = Vector2(11, 20)
	hub.flush()
	check(c.last(HibiraSync.EVENT) != null and c.last(HibiraSync.EVENT).data.s["me/Local"].keys() == ["position"], "changes are sent")

	# A newcomer gets everything again.
	c.sent.clear()
	c.frame("pusher_internal:member_added", {"user_id": "zoe", "user_info": {}}, "presence-play")
	hub.flush()
	check(c.last(HibiraSync.EVENT) != null, "resent when someone joins")

	# Values from the owner apply; from anyone else they do not.
	var payload := {"s": {"bob/Remote": {"position": HibiraSync.encode(Vector2(5, 6)), "modulate": HibiraSync.encode(Color.RED)}}}
	c.frame(HibiraSync.EVENT, payload, "presence-play", "zoe")
	check(remote.position == Vector2.ZERO, "values from someone else are ignored")
	c.frame(HibiraSync.EVENT, payload, "presence-play", "bob")
	check(remote.position == Vector2(5, 6) and remote.modulate == Color.RED, "values from the owner apply")
	c.frame(HibiraSync.EVENT, {"s": {"bob/Remote": {"visible": false}}}, "presence-play", "bob")
	check(remote.visible, "properties not listed are ignored")
	# Our own node is never moved from outside.
	c.frame(HibiraSync.EVENT, {"s": {"me/Local": {"position": HibiraSync.encode(Vector2(99, 99))}}}, "presence-play", "me")
	check(local.position == Vector2(11, 20), "owned nodes ignore incoming values")

	# Interpolation moves towards the value instead of jumping.
	theirs.interpolate = true
	c.frame(HibiraSync.EVENT, {"s": {"bob/Remote": {"position": HibiraSync.encode(Vector2(105, 6))}}}, "presence-play", "bob")
	check(remote.position == Vector2(5, 6), "interpolation does not jump")
	await create_timer(1.5).timeout
	check(remote.position.is_equal_approx(Vector2(105, 6)), "interpolation arrives")

	c.frame("pusher_internal:member_removed", {"user_id": "bob"}, "presence-play")
	check(left == [true], "owner_left when the owner leaves")

	# Many nodes: batches split below the Free plan's 4 KB per event.
	var many: Array[Node] = []
	for i in 120:
		var n := Node2D.new()
		n.position = Vector2(i * 1.25, -i * 2.5)
		var s := HibiraSync.new()
		s.channel_name = "presence-play"
		s.sync_id = "crowd/%d" % i
		s.client_path = c.get_path()
		n.add_child(s)
		root.add_child(n)
		many.append(n)
	await process_frame
	c.sent.clear()
	hub.flush()
	var sent_keys := {}
	var biggest := 0
	for f in c.sent:
		if f.event == HibiraSync.EVENT:
			biggest = maxi(biggest, JSON.stringify(f.data).to_utf8_buffer().size())
			for k in f.data.s:
				if k.begins_with("crowd/"):
					sent_keys[k] = true
	check(biggest > 0 and biggest < 4096, "batches stay under 4 KB (largest %d bytes)" % biggest)
	check(sent_keys.size() == 120, "every node is sent when split (%d)" % sent_keys.size())
	for n in many:
		n.queue_free()

	local.queue_free()
	remote.queue_free()
	c.queue_free()
