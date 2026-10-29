class_name HibiraRoom
extends RefCounted
## Game rooms on presence channels: seats, a host, ready flags, settings,
## kick, start, and chat with typing indicators.
##
## A GDScript port of [url=https://github.com/hibira-io/lobby-js]@hibira-io/lobby[/url]
## that speaks the same client-lobby-* events, so Godot players and browser
## players can share a room. Nothing runs on a server besides the auth
## endpoint: members come from the presence channel, everything else is a
## client event, and every member orders the room by the joined_at the auth
## endpoint signs into user_info (then by user id). The first member is the
## host; members past [member capacity] are told the room is full.
## [codeblock]
## var room := HibiraRoom.join(hibira, "presence-room-42", {"capacity": 4})
## room.joined.connect(func(players, host): render(players))
## room.members_changed.connect(func(players, _joined, _left): render(players))
## room.message_received.connect(func(m): add_chat_line(m.info.name, m.text))
## room.started.connect(func(data, _by): start_game(data))
## room.set_ready(true)
## if room.is_host(): room.start({"seed": 1234})
## [/codeblock]

## Subscribed; [param players] is in seat order (see [method players]).
signal joined(players: Array, host: Variant)
signal members_changed(players: Array, joined: Variant, left: Variant)
signal host_changed(host: Variant, previous: String)
signal settings_changed(settings: Dictionary, by: String)
## The host started the game; [param data] is what they passed to [method start].
signal started(data: Variant, by: String)
## A chat message: {id, from, info, text, extra, at, mine}.
signal message_received(message: Dictionary)
signal typing_changed(typing: Array)
## The host asked you to leave; the room has already left.
signal kicked(by: String, reason: Variant)
## You are past capacity (two players joined at the same moment).
signal full(capacity: int)
## The auth endpoint refused the subscription (403 when the room is full).
signal join_failed(status: int, message: String)

const EVENT_STATE := "client-lobby-state"
const EVENT_READY := "client-lobby-ready"
const EVENT_SETTINGS := "client-lobby-settings"
const EVENT_KICK := "client-lobby-kick"
const EVENT_START := "client-lobby-start"
const EVENT_CHAT := "client-lobby-chat"
const EVENT_TYPING := "client-lobby-typing"
const NO_LIMIT := 1 << 30

var channel: HibiraChannel
var name: String
var capacity := NO_LIMIT
var leave_when_full := true
var max_messages := 100
## Seconds a typing signal lasts.
var typing_timeout := 4.0
## Seconds the host waits before sending its snapshot to a new member.
var state_delay := 0.15
## True once subscribed.
var is_joined := false
## "waiting" until the host calls start(), then "started".
var phase := "waiting"
var settings := {}
## Chat messages received since joining, oldest first.
var messages: Array[Dictionary] = []

var _client: WeakRef
var _ready_flags := {} # id -> bool
var _typing := {} # id -> expiry, seconds
var _host := ""
var _full := false
var _seq := 0
var _state_gen := 0
var _last_typing := -INF
var _owns_subscription := false
var _left := false


## Subscribe to [param channel_name] (a presence- channel) and track it as a
## room. Options: capacity, leave_when_full, max_messages, typing_timeout.
static func join(client: HibiraClient, channel_name: String, options := {}) -> HibiraRoom:
	assert(channel_name.begins_with("presence-") and not channel_name.begins_with("presence-large-"),
		"HibiraRoom: %s is not a presence channel (presence-large- channels do not allow client events)" % channel_name)
	var room := HibiraRoom.new(client, client.subscribe(channel_name), options)
	room._owns_subscription = true
	return room


## Track a channel you subscribed to yourself. Create it right after
## subscribing so no event is missed.
func _init(client: HibiraClient, ch: HibiraChannel, options := {}) -> void:
	_client = weakref(client)
	channel = ch
	name = ch.name
	capacity = int(options.get("capacity", NO_LIMIT))
	leave_when_full = bool(options.get("leave_when_full", true))
	max_messages = int(options.get("max_messages", 100))
	typing_timeout = float(options.get("typing_timeout", 4.0))
	ch.subscribed.connect(_on_subscribed)
	ch.subscription_error.connect(_on_subscription_error)
	ch.member_added.connect(_on_member_added)
	ch.member_removed.connect(_on_member_removed)
	ch.event_received.connect(_on_event)
	if ch.is_subscribed() and not ch.members.is_empty():
		_on_subscribed(null)


# ---- reading the room --------------------------------------------------------

## This connection's member id (empty until joined).
func my_id() -> String:
	return channel.my_id


## Seated members in room order: [{id, info, ready, host, me}].
func players() -> Array:
	return _ordered().slice(0, capacity).map(_member)


## Members past capacity (normally empty, briefly not after a join race).
func waiting() -> Array:
	return _ordered().slice(capacity).map(_member)


## The host member, or null before joining.
func host() -> Variant:
	return null if _host.is_empty() else _member(_host)


func is_host() -> bool:
	return not my_id().is_empty() and _host == my_id()


## The current user's member, or null before joining.
func me() -> Variant:
	return _member(my_id()) if channel.members.has(my_id()) else null


## True when there is at least one player and every player is ready.
func all_ready() -> bool:
	var p := players()
	return not p.is_empty() and p.all(func(m): return m.ready)


## User ids currently typing (yourself excluded).
func typing() -> Array:
	return _typing.keys()


func _member(id: String) -> Dictionary:
	return {"id": id, "info": channel.members.get(id), "ready": _ready_flags.get(id) == true, "host": id == _host, "me": id == my_id()}


func _ordered() -> Array:
	var ids: Array = channel.members.keys()
	ids.sort_custom(func(a, b):
		var ta := _joined_at(channel.members[a])
		var tb := _joined_at(channel.members[b])
		if ta != tb:
			return ta < tb
		return a < b)
	return ids


# ---- actions -----------------------------------------------------------------

func set_ready(ready := true) -> void:
	if not _require_joined():
		return
	_ready_flags[my_id()] = ready
	_trigger(EVENT_READY, {"ready": ready})
	_emit_members(null, null)


## Host only: merge [param patch] into the room settings.
func set_settings(patch: Dictionary) -> void:
	if not _require_host("set_settings"):
		return
	settings.merge(patch, true)
	_seq += 1
	_trigger(EVENT_SETTINGS, {"settings": settings, "seq": _seq})
	settings_changed.emit(settings, my_id())


## Host only: ask a member to leave. To keep someone out for real, refuse them
## in your auth endpoint and terminate their connections with the HTTP API.
func kick(user_id: String, reason: Variant = null) -> void:
	if not _require_host("kick"):
		return
	if user_id == my_id():
		push_error("HibiraRoom: the host cannot kick themselves")
		return
	_trigger(EVENT_KICK, {"user_id": user_id, "reason": reason})


## Host only: start the game. [param data] reaches every member's
## [signal started] (yours too), e.g. a seed. Returns false (and sends
## nothing) when [param require_all_ready] is set and someone is not ready.
func start(data: Variant = null, require_all_ready := false) -> bool:
	if not _require_host("start"):
		return false
	if require_all_ready and not all_ready():
		return false
	phase = "started"
	_seq += 1
	_trigger(EVENT_START, {"data": data, "seq": _seq})
	started.emit(data, my_id())
	return true


## Send a chat message; returns it as stored in [member messages].
func send(text: String, extra: Variant = null) -> Dictionary:
	if not _require_joined():
		return {}
	var msg := {"id": _random_id(), "text": text}
	if extra != null:
		msg.extra = extra
	_trigger(EVENT_CHAT, msg)
	_typing.erase(my_id())
	return _push_message(msg, my_id())


## Tell the room you are typing. Call it on every keystroke; it sends at most
## once every typing_timeout / 2 seconds.
func send_typing() -> void:
	if not _require_joined():
		return
	var now := _now()
	if now - _last_typing < typing_timeout / 2.0:
		return
	_last_typing = now
	_trigger(EVENT_TYPING, {})


## Stop tracking, and unsubscribe when [method join] made the subscription.
func leave() -> void:
	if _left:
		return
	_left = true
	for pair in [
		[channel.subscribed, _on_subscribed],
		[channel.subscription_error, _on_subscription_error],
		[channel.member_added, _on_member_added],
		[channel.member_removed, _on_member_removed],
		[channel.event_received, _on_event],
	]:
		if (pair[0] as Signal).is_connected(pair[1]):
			(pair[0] as Signal).disconnect(pair[1])
	_typing.clear()
	_state_gen += 1
	if _owns_subscription:
		channel.unsubscribe()


func _require_joined() -> bool:
	if not is_joined or _left:
		push_error("HibiraRoom: not joined yet")
		return false
	return true


func _require_host(what: String) -> bool:
	if not _require_joined():
		return false
	if not is_host():
		push_error("HibiraRoom: only the host can %s()" % what)
		return false
	return true


func _trigger(event: String, data: Dictionary) -> void:
	if not channel.trigger(event, data):
		push_warning("HibiraRoom: could not send %s (not connected?)" % event)


# ---- presence ----------------------------------------------------------------

func _on_subscribed(_data: Variant) -> void:
	is_joined = true
	_recompute()
	joined.emit(players(), host())
	_check_full()


func _on_subscription_error(status: int, message: String) -> void:
	join_failed.emit(status, message)


func _on_member_added(id: String, _info: Variant) -> void:
	_recompute()
	_emit_members(_member(id), null)
	if is_host():
		_schedule_state()
	# Two members authorized at nearly the same time can both pass a capacity
	# check; the one that joined later is the one past capacity.
	_check_full()


func _on_member_removed(id: String, info: Variant) -> void:
	var gone := {"id": id, "info": info, "ready": _ready_flags.get(id) == true, "host": id == _host, "me": false}
	_ready_flags.erase(id)
	var was_typing := _typing.erase(id)
	_recompute()
	_emit_members(null, gone)
	if was_typing:
		typing_changed.emit(typing())


func _recompute() -> void:
	var prev := _host
	var order := _ordered()
	_host = order[0] if not order.is_empty() else ""
	if not prev.is_empty() and prev != _host:
		host_changed.emit(host(), prev)


func _check_full() -> void:
	if _full or my_id().is_empty():
		return
	if _ordered().find(my_id()) >= capacity:
		_full = true
		full.emit(capacity)
		if leave_when_full:
			leave()


func _emit_members(joined_member: Variant, left_member: Variant) -> void:
	members_changed.emit(players(), joined_member, left_member)


func _schedule_state() -> void:
	_state_gen += 1
	var gen := _state_gen
	await _wait(state_delay)
	if gen != _state_gen or _left or not is_host():
		return
	_trigger(EVENT_STATE, {"settings": settings, "ready": _ready_flags.duplicate(), "phase": phase, "seq": _seq})


# ---- client events -----------------------------------------------------------

func _on_event(event: String, data: Variant, user_id: String) -> void:
	if _left:
		return
	var d: Dictionary = data if data is Dictionary else {}
	match event:
		EVENT_STATE:
			if user_id.is_empty() or user_id != _host:
				return
			if d.get("seq") is float and int(d.seq) < _seq:
				return
			_seq = int(d.get("seq", _seq))
			settings = d.get("settings", {}) if d.get("settings") is Dictionary else {}
			phase = str(d.get("phase", phase))
			var flags: Variant = d.get("ready", {})
			if flags is Dictionary:
				for id in flags:
					if id != my_id() and channel.members.has(id):
						_ready_flags[id] = flags[id] == true
			settings_changed.emit(settings, user_id)
			_emit_members(null, null)
		EVENT_READY:
			if user_id.is_empty() or not channel.members.has(user_id):
				return
			_ready_flags[user_id] = d.get("ready") == true
			_emit_members(null, null)
		EVENT_SETTINGS:
			if user_id.is_empty() or user_id != _host:
				return
			_seq = maxi(_seq, int(d.get("seq", 0)))
			settings = d.get("settings", {}) if d.get("settings") is Dictionary else {}
			settings_changed.emit(settings, user_id)
		EVENT_KICK:
			if user_id.is_empty() or user_id != _host or str(d.get("user_id", "")) != my_id():
				return
			var reason: Variant = d.get("reason")
			leave()
			kicked.emit(user_id, reason)
		EVENT_START:
			if user_id.is_empty() or user_id != _host:
				return
			_seq = maxi(_seq, int(d.get("seq", 0)))
			phase = "started"
			started.emit(d.get("data"), user_id)
		EVENT_CHAT:
			if user_id.is_empty() or not (d.get("text") is String):
				return
			var was_typing := _typing.erase(user_id)
			_push_message(d, user_id)
			if was_typing:
				typing_changed.emit(typing())
		EVENT_TYPING:
			_on_typing(user_id)


func _on_typing(id: String) -> void:
	if id.is_empty() or id == my_id() or not channel.members.has(id):
		return
	var had := _typing.has(id)
	var expires := _now() + typing_timeout
	_typing[id] = expires
	if not had:
		typing_changed.emit(typing())
	await _wait(typing_timeout)
	if _typing.get(id) == expires:
		_typing.erase(id)
		typing_changed.emit(typing())


func _push_message(d: Dictionary, from: String) -> Dictionary:
	var msg := {
		"id": d.id if d.get("id") is String else _random_id(),
		"from": from,
		"info": channel.members.get(from),
		"text": d.text,
		"extra": d.get("extra"),
		"at": Time.get_unix_time_from_system(),
		"mine": from == my_id(),
	}
	messages.append(msg)
	if messages.size() > max_messages:
		messages = messages.slice(messages.size() - max_messages)
	message_received.emit(msg)
	return msg


func _wait(seconds: float) -> void:
	var client: HibiraClient = _client.get_ref()
	if client != null and client.is_inside_tree():
		await client.get_tree().create_timer(seconds).timeout


static func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


static func _joined_at(info: Variant) -> float:
	if info is Dictionary and (info.get("joined_at") is float or info.get("joined_at") is int):
		return float(info.joined_at)
	return INF


static func _random_id() -> String:
	var bytes := Crypto.new().generate_random_bytes(16)
	bytes[6] = (bytes[6] & 0x0f) | 0x40
	bytes[8] = (bytes[8] & 0x3f) | 0x80
	var h := bytes.hex_encode()
	return "%s-%s-%s-%s-%s" % [h.substr(0, 8), h.substr(8, 4), h.substr(12, 4), h.substr(16, 4), h.substr(20)]
