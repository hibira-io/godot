extends SceneTree
# Offline tests for HibiraMatch and HibiraQueue.
#
#   godot --headless --import && godot --headless --script res://tests/test_queue.gd

const FakeClient := preload("res://tests/fake_client.gd")
const Q := "presence-queue-duo"

var failures := 0
var checks := 0


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("FAIL: ", what)


func _initialize() -> void:
	await process_frame
	test_rules()
	await test_host_matches()
	await test_follower()
	await test_batches()
	await test_timeout()
	print("%d checks, %d failed" % [checks, failures])
	quit(1 if failures > 0 else 0)


func ticket(id: String, joined_at: float, rating := 0.0, criteria := {}) -> Dictionary:
	return {"id": id, "joined_at": joined_at, "rating": rating, "criteria": criteria}


func ids(matches: Array) -> Array:
	return matches.map(func(m): return m.players)


func test_rules() -> void:
	check(HibiraMatch.allowed_range(0, {"rating_range": 100, "widen_by": 50, "widen_every": 5}) == 100, "range at start")
	check(HibiraMatch.allowed_range(11, {"rating_range": 100, "widen_by": 50, "widen_every": 5}) == 200, "range widens")
	check(HibiraMatch.allowed_range(60, {"rating_range": 100, "widen_by": 50, "widen_every": 5, "max_range": 250}) == 250, "range capped")
	check(HibiraMatch.allowed_range(1000, {}) == INF, "no range by default")

	check(HibiraMatch.criteria_fit({"mode": "duo"}, {"mode": "duo", "region": "hkg"}), "missing key is a wildcard")
	check(not HibiraMatch.criteria_fit({"mode": "duo"}, {"mode": "solo"}), "different values")
	check(HibiraMatch.criteria_fit({"region": ["hkg", "tyo"]}, {"region": "tyo"}), "arrays overlap")
	check(not HibiraMatch.criteria_fit({"region": ["hkg"]}, {"region": ["sin"]}), "arrays apart")
	check(not HibiraMatch.criteria_fit({"level": 1.0}, {"level": "1"}), "number and string differ")
	check(HibiraMatch.criteria_fit({"level": 2}, {"level": 2.0}), "int and float are equal numbers")

	var now := 100000.0
	var m := HibiraMatch.find_matches([ticket("c", 3000, 1500), ticket("a", 1000, 1000), ticket("b", 2000, 1020)], {"size": 2, "rating_range": 100}, now)
	check(ids(m) == [["a", "b"]], "closest ratings matched, oldest first")
	m = HibiraMatch.find_matches([ticket("a", 1000, 1000), ticket("b", 2000, 5000)], {"size": 2, "rating_range": 100}, now)
	check(m.is_empty(), "too far apart")
	m = HibiraMatch.find_matches([ticket("a", 1000, 1000), ticket("b", 2000, 5000)], {"size": 2, "rating_range": 100, "widen_by": 1000, "widen_every": 10}, now)
	check(ids(m) == [["a", "b"]], "range widened by waiting")
	# Both fit an anchor with no region, but not each other.
	m = HibiraMatch.find_matches([ticket("a", 1000), ticket("b", 2000, 0, {"region": "hkg"}), ticket("c", 3000, 0, {"region": "tyo"})], {"size": 3}, now)
	check(m.is_empty(), "every pair must fit")
	m = HibiraMatch.find_matches([ticket("a", 1000), ticket("b", 2000)], {"size": 4, "min_size": 2, "fill_after": 30}, now)
	check(ids(m) == [["a", "b"]], "smaller match after fill_after")
	m = HibiraMatch.find_matches([ticket("a", now - 1000), ticket("b", now - 500)], {"size": 4, "min_size": 2, "fill_after": 30}, now)
	check(m.is_empty(), "no smaller match before fill_after")
	m = HibiraMatch.find_matches([ticket("a", 1000), ticket("b", 2000), ticket("c", 3000)], {"size": 2, "compatible": func(x, y): return x.id != "a" and y.id != "a"}, now)
	check(ids(m) == [["b", "c"]], "compatible rule")


func new_client(user_id: String, joined_at: float, rating: float) -> FakeClient:
	var c := FakeClient.new()
	c.app_key = "k"
	c.authorizer = func(socket_id: String, channel_name: String) -> Dictionary:
		var info := {"name": user_id, "joined_at": joined_at}
		if channel_name.begins_with("presence-queue-"):
			info.rating = rating
			info.criteria = {"mode": "duo"}
		return {"auth": "k:sig-%s-%s" % [socket_id, channel_name], "channel_data": JSON.stringify({"user_id": user_id, "user_info": info})}
	root.add_child(c)
	return c


func hash_of(members: Dictionary) -> Dictionary:
	return {"presence": {"ids": members.keys(), "count": members.size(), "hash": members}}


func test_host_matches() -> void:
	var c := new_client("a", 1000, 1000)
	var queue := HibiraQueue.join(c, Q, {"size": 2, "rating_range": 100, "interval": 0.05})
	var got := {"joined": [], "matched": []}
	queue.joined.connect(func(u): got.joined.append(u))
	queue.matched.connect(func(m): got.matched.append(m))
	c.frame("pusher:connection_established", {"socket_id": "1.1"})
	await process_frame
	c.frame("pusher_internal:subscription_succeeded", hash_of({
		"a": {"name": "A", "joined_at": 1000, "rating": 1000},
		"z": {"name": "Z", "joined_at": 1500, "rating": 5000},
	}), Q)
	check(got.joined.size() == 1 and got.joined[0].host and got.joined[0].position == 1 and got.joined[0].count == 2, "joined as host")
	check(c.last(HibiraQueue.EVENT_MATCH) == null, "no match for a far rating")

	c.frame("pusher_internal:member_added", {"user_id": "b", "user_info": {"name": "B", "joined_at": 2000, "rating": 1030}}, Q)
	var sent: Variant = c.last(HibiraQueue.EVENT_MATCH)
	check(sent != null and sent.channel == Q and sent.data.matches.size() == 1, "host announces the match")
	var m: Dictionary = sent.data.matches[0] if sent != null else {}
	check(m.get("players") == ["a", "b"] and str(m.get("id", "")).length() == 32, "match players and random id")
	check(got.matched.size() == 1 and queue.status == "matched", "host is matched too")
	if got.matched.size() == 1:
		var found: Dictionary = got.matched[0]
		check(found.channel == "presence-match-" + m.id and found.room is HibiraRoom and found.room.capacity == 2, "match room joined")
		check(found.players.map(func(p): return p.id) == ["a", "b"] and found.players[0].me, "match players")
		await process_frame
		check(c.last("pusher:unsubscribe") != null and c.last("pusher:unsubscribe").data.channel == Q, "left the queue")
		check(c.channel(found.channel) != null, "subscribed to the match room")
	c.queue_free()


func test_follower() -> void:
	var c := new_client("b", 2000, 1030)
	var queue := HibiraQueue.join(c, Q, {"size": 2})
	var got := {"matched": [], "updates": 0}
	queue.matched.connect(func(m): got.matched.append(m))
	queue.updated.connect(func(_u): got.updates += 1)
	c.frame("pusher:connection_established", {"socket_id": "2.2"})
	await process_frame
	c.frame("pusher_internal:subscription_succeeded", hash_of({
		"a": {"joined_at": 1000, "rating": 1000},
		"b": {"joined_at": 2000, "rating": 1030},
		"c": {"joined_at": 3000, "rating": 1010},
		"d": {"joined_at": 4000, "rating": 1020},
	}), Q)
	check(not queue.is_host() and queue.position() == 2, "follower position")
	check(c.last(HibiraQueue.EVENT_MATCH) == null, "only the host matches")

	c.frame(HibiraQueue.EVENT_MATCH, {"matches": [{"id": "f".repeat(32), "players": ["b", "c"]}]}, Q, "c")
	check(got.matched.is_empty(), "match from a non-host ignored")

	# The host pairs a with c; we are left waiting and c is no longer counted.
	c.frame(HibiraQueue.EVENT_MATCH, {"matches": [{"id": "1".repeat(32), "players": ["a", "c"]}]}, Q, "a")
	check(got.matched.is_empty() and queue.count() == 2 and queue.position() == 1, "others matched, still waiting")
	# The host leaves before c does: we take over, and must not match c again.
	c.frame("pusher_internal:member_removed", {"user_id": "a"}, Q)
	check(queue.is_host(), "host hand-over")
	var sent: Variant = c.last(HibiraQueue.EVENT_MATCH)
	check(sent == null, "no match while only claimed players are left with us")
	await create_timer(1.2).timeout
	sent = c.last(HibiraQueue.EVENT_MATCH)
	check(sent != null and sent.data.matches[0].players == ["b", "d"], "new host matches the remaining players")
	check(got.matched.size() == 1 and got.matched[0].room.capacity == 2, "matched as the new host")
	c.queue_free()


func test_batches() -> void:
	var c := new_client("p00", 1000, 0)
	var queue := HibiraQueue.join(c, Q, {"size": 2, "max_event_bytes": 300, "max_events_per_tick": 2, "auto_room": false})
	c.frame("pusher:connection_established", {"socket_id": "3.3"})
	await process_frame
	var members := {}
	for i in 20:
		members["p%02d" % i] = {"joined_at": 1000 + i, "rating": 0}
	c.frame("pusher_internal:subscription_succeeded", hash_of(members), Q)
	var events := c.sent.filter(func(s): return s.event == HibiraQueue.EVENT_MATCH)
	check(events.size() == 1, "host matched in the first batch stops the queue")
	if events.size() == 1:
		check(JSON.stringify(events[0].data).length() <= 300, "batch under max_event_bytes")
		check(events[0].data.matches[0].players == ["p00", "p01"], "first batch has the oldest players")
	check(queue.status == "matched" and queue.match_found.room == null, "no room with auto_room off")
	c.queue_free()


func test_timeout() -> void:
	var c := new_client("solo", 1000, 0)
	var queue := HibiraQueue.join(c, Q, {"timeout": 0.1})
	var got := []
	queue.timed_out.connect(func(w): got.append(w))
	c.frame("pusher:connection_established", {"socket_id": "4.4"})
	await process_frame
	c.frame("pusher_internal:subscription_succeeded", hash_of({"solo": {"joined_at": 1000}}), Q)
	await create_timer(0.3).timeout
	check(got.size() == 1 and queue.status == "timeout", "timed out")
	check(c.last("pusher:unsubscribe") != null, "left after timeout")

	var refused := []
	var c2 := FakeClient.new()
	c2.app_key = "k"
	c2.authorizer = func(_s, _n): return {"status": 403, "error": "banned"}
	root.add_child(c2)
	var queue2 := HibiraQueue.join(c2, Q)
	queue2.join_failed.connect(func(s, msg): refused.append([s, msg]))
	c2.frame("pusher:connection_established", {"socket_id": "5.5"})
	await process_frame
	check(refused == [[403, "banned"]], "auth refusal reaches join_failed")
	c.queue_free()
	c2.queue_free()
