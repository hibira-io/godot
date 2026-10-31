class_name HibiraQueue
extends RefCounted
## A matchmaking queue on a presence channel, with no game server.
##
## A GDScript port of the Queue in
## [url=https://github.com/hibira-io/lobby-js]@hibira-io/lobby[/url] that
## speaks the same client-queue-match event, so Godot, Unity, Cocos and browser
## players can wait in one queue. Your auth endpoint signs joined_at, rating
## and criteria into user_info (authorizeQueue in @hibira-io/lobby/server), so
## nobody can change their own rating or jump the queue.
##
## The member who has waited longest hosts the queue: it runs the rules in
## [HibiraMatch] and announces matches with one client event, which the server
## stamps with its user id. Matched players leave the queue and join a
## [HibiraRoom] on presence-match-<random id>.
## [codeblock]
## var queue := HibiraQueue.join(hibira, "presence-queue-duo", {
##     "size": 2, "rating_range": 100, "widen_by": 50, "widen_every": 5, "timeout": 60,
## })
## queue.matched.connect(func(m): go_to_room(m.room))
## queue.timed_out.connect(func(_waited): show_no_match())
## [/codeblock]
## Keep every client on the same options: the host's are the ones that count.

## Subscribed; [param update] is {position, count, waited, range, host}.
signal joined(update: Dictionary)
## Someone joined, left or was matched.
signal updated(update: Dictionary)
## You were matched: {id, channel, players: [{id, info, me}], room}. The
## queue has already left; room is a HibiraRoom (null when auto_room is off).
signal matched(found: Dictionary)
## No match within timeout seconds; the queue has already left.
signal timed_out(waited: float)
## The auth endpoint refused the subscription.
signal join_failed(status: int, message: String)

const EVENT_MATCH := "client-queue-match"
const DEFAULTS := {
	## Seconds before giving up; INF waits forever.
	"timeout": 60.0,
	## Seconds between matching rounds on the host.
	"interval": 1.0,
	"room_prefix": "presence-match-",
	## Join the match room (join() only).
	"auto_room": true,
	"room_options": {},
	## Matches per client event stay under this size (Free plan events are 4 KB).
	"max_event_bytes": 3000,
	## Client events per round, under the 10 per second limit.
	"max_events_per_tick": 3,
}

var channel: HibiraChannel
var name: String
## Matching rules ([HibiraMatch]) and the options above.
var options: Dictionary
## True once subscribed.
var is_joined := false
## "waiting", then "matched", "timeout" or "left".
var status := "waiting"
## The match once found (see [signal matched]); empty before.
var match_found := {}

var _client: WeakRef
var _claimed := {}
var _host := ""
var _host_gen := 0
var _owns_subscription := false
var _left := false


## Subscribe to [param channel_name] (a presence- channel) and wait in it.
## Options: the [HibiraMatch] rules plus timeout, interval, room_prefix,
## auto_room, room_options, max_event_bytes, max_events_per_tick.
static func join(client: HibiraClient, channel_name: String, opts := {}) -> HibiraQueue:
	assert(channel_name.begins_with("presence-") and not channel_name.begins_with("presence-large-"),
		"HibiraQueue: %s is not a presence channel (presence-large- channels do not allow client events)" % channel_name)
	var queue := HibiraQueue.new(client, client.subscribe(channel_name), opts)
	queue._owns_subscription = true
	return queue


## Track a channel you subscribed to yourself. Create it right after
## subscribing so no event is missed. Without [method join] the queue does
## not open the match room; [signal matched] still names its channel.
func _init(client: HibiraClient, ch: HibiraChannel, opts := {}) -> void:
	_client = weakref(client)
	channel = ch
	name = ch.name
	options = HibiraMatch.DEFAULTS.duplicate()
	options.merge(DEFAULTS.duplicate(true), true)
	options.merge(opts, true)
	ch.subscribed.connect(_on_subscribed)
	ch.subscription_error.connect(_on_subscription_error)
	ch.member_added.connect(_on_member_added)
	ch.member_removed.connect(_on_member_removed)
	ch.event_received.connect(_on_event)
	if ch.is_subscribed() and not ch.members.is_empty():
		_on_subscribed.call_deferred(null)


# ---- reading the queue -------------------------------------------------------

## This connection's member id (empty until joined).
func my_id() -> String:
	return channel.my_id


## Players still waiting, longest wait first: [{id, joined_at, rating, criteria, info}].
func tickets() -> Array:
	return _ordered().filter(func(id): return not _claimed.has(id)).map(func(id): return _ticket(id, channel.members[id]))


## Players waiting, yourself included.
func count() -> int:
	return tickets().size()


## Your place in the queue, 1 for the longest wait; 0 before joining or after a match.
func position() -> int:
	var ids := tickets().map(func(t): return t.id)
	return ids.find(my_id()) + 1


## Your own ticket as the host sees it, or an empty Dictionary.
func my_ticket() -> Dictionary:
	if my_id().is_empty() or not channel.members.has(my_id()):
		return {}
	return _ticket(my_id(), channel.members[my_id()])


## Seconds you have waited, by your signed joined_at.
func waited() -> float:
	var t := my_ticket()
	if t.is_empty() or t.joined_at == INF:
		return 0.0
	return maxf(0.0, (_now_ms() - float(t.joined_at)) / 1000.0)


## The rating range you accept now.
func current_range() -> float:
	return HibiraMatch.allowed_range(waited(), options)


func is_host() -> bool:
	return not my_id().is_empty() and _host == my_id()


func _ordered() -> Array:
	var ids: Array = channel.members.keys()
	ids.sort_custom(func(a, b):
		var ta := _joined_at(channel.members[a])
		var tb := _joined_at(channel.members[b])
		if ta != tb:
			return ta < tb
		return a < b)
	return ids


func _update() -> Dictionary:
	return {"position": position(), "count": count(), "waited": waited(), "range": current_range(), "host": is_host()}


# ---- actions -----------------------------------------------------------------

## Leave the queue without a match.
func leave() -> void:
	_close("left")


func _close(new_status: String) -> void:
	if _left:
		return
	_left = true
	if status == "waiting":
		status = new_status
	_host_gen += 1
	for pair in [
		[channel.subscribed, _on_subscribed],
		[channel.subscription_error, _on_subscription_error],
		[channel.member_added, _on_member_added],
		[channel.member_removed, _on_member_removed],
		[channel.event_received, _on_event],
	]:
		if (pair[0] as Signal).is_connected(pair[1]):
			(pair[0] as Signal).disconnect(pair[1])
	if _owns_subscription:
		channel.unsubscribe()


# ---- presence ----------------------------------------------------------------

func _on_subscribed(_data: Variant) -> void:
	if _left or is_joined:
		return
	is_joined = true
	_recompute()
	joined.emit(_update())
	_start_timeout()
	_tick()


func _on_subscription_error(code: int, message: String) -> void:
	join_failed.emit(code, message)


func _on_member_added(id: String, _info: Variant) -> void:
	_claimed.erase(id)
	_recompute()
	updated.emit(_update())
	_tick()


func _on_member_removed(id: String, _info: Variant) -> void:
	_claimed.erase(id)
	_recompute()
	updated.emit(_update())


func _recompute() -> void:
	var was_host := is_host()
	var order := _ordered()
	_host = order[0] if not order.is_empty() else ""
	if is_host() and not was_host:
		_run_host_loop()
	elif not is_host() and was_host:
		_host_gen += 1


func _run_host_loop() -> void:
	_host_gen += 1
	var gen := _host_gen
	while true:
		if not await _wait(float(options.interval)):
			return
		if gen != _host_gen or _left:
			return
		_tick()


func _start_timeout() -> void:
	var timeout := float(options.timeout)
	if not is_finite(timeout) or timeout < 0:
		return
	if not await _wait(timeout):
		return
	if status != "waiting" or _left:
		return
	status = "timeout"
	var w := waited()
	timed_out.emit(w)
	_close("timeout")


# ---- matching (host only) ----------------------------------------------------

func _tick() -> void:
	if _left or not is_joined or not is_host():
		return
	var found := HibiraMatch.find_matches(tickets(), options, _now_ms()).map(
		func(m): return {"id": _random_id(), "players": m.players})
	if found.is_empty():
		return

	# One client event per batch keeps each event under the Free plan's 4 KB;
	# a few batches per round stay under the client event rate limit.
	var batches := []
	var batch := []
	for m in found:
		if not batch.is_empty() and JSON.stringify({"matches": batch + [m]}).length() > int(options.max_event_bytes):
			batches.append(batch)
			batch = []
		batch.append(m)
	if not batch.is_empty():
		batches.append(batch)

	for b in batches.slice(0, int(options.max_events_per_tick)):
		if not channel.trigger(EVENT_MATCH, {"matches": b}):
			push_warning("HibiraQueue: could not send %s (not connected?)" % EVENT_MATCH)
			return
		# Our own event is not echoed back, so apply it here too.
		_apply_matches(b)
		if _left:
			return


# ---- client events -----------------------------------------------------------

func _on_event(event: String, data: Variant, user_id: String) -> void:
	if _left or event != EVENT_MATCH:
		return
	if user_id.is_empty() or user_id != _host:
		return
	if data is Dictionary and data.get("matches") is Array:
		_apply_matches(data.matches)


func _apply_matches(matches: Array) -> void:
	var mine := {}
	for m in matches:
		if not (m is Dictionary) or not (m.get("id") is String) or not (m.get("players") is Array):
			continue
		var players: Array = m.players.map(func(p): return str(p))
		# A player already claimed by an earlier match cannot be in a second one.
		if players.any(func(p): return _claimed.has(p)):
			continue
		for p in players:
			_claimed[p] = true
		if mine.is_empty() and players.has(my_id()):
			mine = {"id": m.id, "players": players}
	if mine.is_empty():
		updated.emit(_update())
	else:
		_matched(mine)


func _matched(m: Dictionary) -> void:
	if status != "waiting" or _left:
		return
	status = "matched"
	var room_channel: String = str(options.room_prefix) + m.id
	var players: Array = m.players.map(func(id): return {"id": id, "info": channel.members.get(id), "me": id == my_id()})
	var room: HibiraRoom = null
	var client: HibiraClient = _client.get_ref()
	if _owns_subscription and options.auto_room and client != null:
		var room_opts := {"capacity": players.size()}
		room_opts.merge(options.room_options, true)
		room = HibiraRoom.join(client, room_channel, room_opts)
	match_found = {"id": m.id, "channel": room_channel, "players": players, "room": room}
	_close("matched")
	matched.emit(match_found)


# ---- helpers -----------------------------------------------------------------

func _wait(seconds: float) -> bool:
	var client: HibiraClient = _client.get_ref()
	if client == null or not client.is_inside_tree():
		return false
	await client.get_tree().create_timer(seconds).timeout
	return true


static func _ticket(id: String, info: Variant) -> Dictionary:
	var i: Dictionary = info if info is Dictionary else {}
	var rating: Variant = i.get("rating")
	return {
		"id": id,
		"joined_at": _joined_at(i),
		"rating": float(rating) if (rating is float or rating is int) and is_finite(float(rating)) else 0.0,
		"criteria": i.criteria if i.get("criteria") is Dictionary else {},
		"info": info,
	}


static func _joined_at(info: Variant) -> float:
	if info is Dictionary and (info.get("joined_at") is float or info.get("joined_at") is int):
		return float(info.joined_at)
	return INF


static func _now_ms() -> float:
	return Time.get_unix_time_from_system() * 1000.0


static func _random_id() -> String:
	return Crypto.new().generate_random_bytes(16).hex_encode()
