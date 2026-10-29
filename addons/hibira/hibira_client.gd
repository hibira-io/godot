@icon("res://addons/hibira/icon.svg")
class_name HibiraClient
extends Node
## A Pusher Channels protocol (v7) client for Hibira and other
## Pusher-compatible servers.
##
## Add it to your scene (or as an autoload), set [member app_key], and call
## [method connect_to_server]. Public channels need nothing else. Private and
## presence channels are signed by your own backend: set [member auth_endpoint]
## (the same endpoint pusher-js would use) or [member authorizer].
## [codeblock]
## var hibira := HibiraClient.new()
## hibira.app_key = "your-app-key"
## hibira.auth_endpoint = "https://your-game.example/hibira/auth"
## add_child(hibira)
## hibira.connect_to_server()
##
## var room := hibira.subscribe("presence-room-42")
## room.subscribed.connect(func(_data): print("members: ", room.members))
## room.bind("client-move", func(data, user_id): print(user_id, " moved ", data))
## room.trigger("client-move", {"x": 3, "y": 4})
## [/codeblock]
## Works in native and web exports: on the web, WebSocketPeer and HTTPRequest
## use the browser's WebSocket and fetch.

## The connection has changed state. See [enum State].
signal state_changed(state: State)
## Connected, with the socket id the server gave this connection.
signal connected(socket_id: String)
## The connection closed. [param will_reconnect] is false after
## [method disconnect_from_server] or a close code the server says not to
## retry (4000-4099).
signal disconnected(code: int, reason: String, will_reconnect: bool)
## The server sent pusher:error, or a request failed.
signal error(code: int, message: String)
## Any event on any channel (pusher_internal events excluded).
signal event_received(channel: String, event: String, data: Variant, user_id: String)

enum State { DISCONNECTED, CONNECTING, CONNECTED, RECONNECTING }

const VERSION := "0.1.0"
const PROTOCOL := 7

## The app key from the Hibira portal. Never put the app secret in a game.
@export var app_key := ""
## WebSocket host. Hibira: ws.hibira.io.
@export var host := "ws.hibira.io"
@export var port := 443
@export var use_tls := true
## URL that signs private and presence subscriptions: it gets a form POST with
## socket_id and channel_name (plus [member auth_params]) and returns
## {"auth": ..., "channel_data": ...}, as for pusher-js.
@export var auth_endpoint := ""
## Extra headers for the auth request, e.g. ["Authorization: Bearer <token>"].
@export var auth_headers := PackedStringArray()
## Extra form fields for the auth request.
@export var auth_params := {}
## Reconnect after a dropped connection, with backoff.
@export var auto_reconnect := true
## Seconds without traffic before the client pings the server. The server's
## own activity_timeout wins when it is shorter.
@export var activity_timeout := 120.0
## Seconds to wait for any reply to a ping before reconnecting.
@export var pong_timeout := 30.0

## Optional: sign subscriptions yourself instead of [member auth_endpoint].
## Called as [code]authorizer.call(socket_id, channel_name)[/code] and may be a
## coroutine; returns a Dictionary with "auth" (and "channel_data" for
## presence), or an empty Dictionary to refuse.
var authorizer := Callable()

var state := State.DISCONNECTED
## This connection's socket id, empty until connected.
var socket_id := ""

var _ws := WebSocketPeer.new()
var _channels := {} # name -> HibiraChannel
var _want_connection := false
var _attempt := 0
var _retry_at := -1.0
var _last_activity := 0.0
var _ping_sent_at := -1.0
var _server_timeout := 0.0
var _active := false # a socket is open or opening
var _was_open := false


func _ready() -> void:
	set_process(true)


func _exit_tree() -> void:
	_want_connection = false
	if _active:
		_ws.close(1000, "")


## Open the connection. Channels you subscribed to are (re)subscribed once it
## is up.
func connect_to_server() -> void:
	if app_key.is_empty():
		push_error("HibiraClient: app_key is not set")
		return
	_want_connection = true
	_retry_at = -1.0
	if not _active:
		_open()


## Close the connection and stop reconnecting. Subscriptions are kept and come
## back on the next [method connect_to_server].
func disconnect_from_server() -> void:
	_want_connection = false
	_retry_at = -1.0
	if _active:
		_ws.close(1000, "client disconnect")
	else:
		_set_state(State.DISCONNECTED)


## Subscribe to a channel, or return the existing subscription.
func subscribe(channel_name: String) -> HibiraChannel:
	if _channels.has(channel_name):
		return _channels[channel_name]
	var ch := HibiraChannel.new(self, channel_name)
	_channels[channel_name] = ch
	if state == State.CONNECTED:
		_subscribe(ch)
	return ch


func unsubscribe(channel_name: String) -> void:
	var ch: HibiraChannel = _channels.get(channel_name)
	if ch == null:
		return
	_channels.erase(channel_name)
	if ch.is_subscribed() and state == State.CONNECTED:
		_send({"event": "pusher:unsubscribe", "data": {"channel": channel_name}})
	ch._reset()


## The subscription to [param channel_name], or null.
func channel(channel_name: String) -> HibiraChannel:
	return _channels.get(channel_name)


func channels() -> Array:
	return _channels.values()


## Send a client event (its name must start with "client-") on a private or
## presence channel you are subscribed to. The app needs client events turned
## on. Returns false when not connected.
func trigger(channel_name: String, event: String, data: Variant) -> bool:
	if not event.begins_with("client-"):
		push_error("HibiraClient: client event names start with \"client-\": %s" % event)
		return false
	if not (channel_name.begins_with("private-") or channel_name.begins_with("presence-")):
		push_error("HibiraClient: client events need a private or presence channel: %s" % channel_name)
		return false
	if state != State.CONNECTED:
		return false
	return _send({"event": event, "channel": channel_name, "data": data})


# ---- connection --------------------------------------------------------------

func _url() -> String:
	var scheme := "wss" if use_tls else "ws"
	var default_port := 443 if use_tls else 80
	var authority := host if port == default_port else "%s:%d" % [host, port]
	return "%s://%s/app/%s?protocol=%d&client=godot&version=%s" % [scheme, authority, app_key.uri_encode(), PROTOCOL, VERSION]


func _open() -> void:
	_ws = WebSocketPeer.new()
	_was_open = false
	_set_state(State.CONNECTING if _attempt == 0 else State.RECONNECTING)
	var err := _ws.connect_to_url(_url())
	_active = err == OK
	if err != OK:
		error.emit(err, "could not open %s" % _url())
		_schedule_reconnect(1006)


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if _retry_at >= 0.0 and now >= _retry_at:
		_retry_at = -1.0
		if _want_connection:
			_open()
	if not _active:
		return
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not _was_open:
				_was_open = true
				_last_activity = now
			while _ws.get_available_packet_count() > 0:
				_last_activity = now
				_ping_sent_at = -1.0
				_handle_message(_ws.get_packet().get_string_from_utf8())
			if state == State.CONNECTED:
				_check_activity(now)
		WebSocketPeer.STATE_CLOSED:
			_active = false
			_closed(_ws.get_close_code(), _ws.get_close_reason())


func _check_activity(now: float) -> void:
	var limit := activity_timeout
	if _server_timeout > 0.0:
		limit = minf(limit, _server_timeout)
	if _ping_sent_at >= 0.0:
		if now - _ping_sent_at > pong_timeout:
			_ping_sent_at = -1.0
			_ws.close(4201, "pong timeout")
	elif now - _last_activity > limit:
		_ping_sent_at = now
		_send({"event": "pusher:ping", "data": {}})


func _closed(code: int, reason: String) -> void:
	_was_open = false
	socket_id = ""
	for ch: HibiraChannel in _channels.values():
		ch._reset()
	var retry := _want_connection and auto_reconnect and not (code >= 4000 and code <= 4099)
	if code >= 4000 and code <= 4099:
		_want_connection = false
	disconnected.emit(code, reason, retry)
	if retry:
		_schedule_reconnect(code)
	else:
		_set_state(State.DISCONNECTED)


func _schedule_reconnect(code: int) -> void:
	_set_state(State.RECONNECTING)
	var delay: float
	if code >= 4200 and code <= 4299:
		delay = 0.0 # the server asks for an immediate reconnect
	elif code >= 4100 and code <= 4199:
		delay = 1.0 + _attempt # over capacity: back off
	else:
		delay = minf(30.0, pow(2.0, _attempt)) * randf_range(0.5, 1.0)
	_attempt += 1
	_retry_at = Time.get_ticks_msec() / 1000.0 + delay


func _set_state(s: State) -> void:
	if s == state:
		return
	state = s
	state_changed.emit(s)


func _send(message: Dictionary) -> bool:
	if _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return false
	return _ws.send_text(JSON.stringify(message)) == OK


# ---- protocol ----------------------------------------------------------------

func _handle_message(text: String) -> void:
	var msg: Variant = _parse(text)
	if typeof(msg) != TYPE_DICTIONARY or not msg.has("event"):
		return
	var event: String = msg.event
	var data: Variant = _parse(msg.get("data"))
	var channel_name: String = msg.get("channel", "")
	match event:
		"pusher:connection_established":
			var d: Dictionary = data if data is Dictionary else {}
			socket_id = str(d.get("socket_id", ""))
			_server_timeout = float(d.get("activity_timeout", 0))
			_attempt = 0
			_set_state(State.CONNECTED)
			connected.emit(socket_id)
			for ch: HibiraChannel in _channels.values():
				_subscribe(ch)
			return
		"pusher:error":
			var d: Dictionary = data if data is Dictionary else {}
			var code: Variant = d.get("code")
			error.emit(int(code) if code != null else 0, str(d.get("message", "")))
			return
		"pusher:ping":
			_send({"event": "pusher:pong", "data": {}})
			return
		"pusher:pong":
			return
	var ch: HibiraChannel = _channels.get(channel_name)
	if ch != null:
		ch._handle(event, data, str(msg.get("user_id", "")))
	if not event.begins_with("pusher_internal:"):
		event_received.emit(channel_name, event, data, str(msg.get("user_id", "")))


func _subscribe(ch: HibiraChannel) -> void:
	var channel_name := ch.name
	if channel_name.begins_with("private-encrypted-"):
		ch._failed(0, "encrypted channels are not supported")
		return
	if not (channel_name.begins_with("private-") or channel_name.begins_with("presence-")):
		_send({"event": "pusher:subscribe", "data": {"channel": channel_name}})
		return
	var sid := socket_id
	var auth: Dictionary = await _authorize(channel_name)
	# The connection may have dropped, or the channel been unsubscribed, while
	# the auth request was in flight.
	if sid != socket_id or _channels.get(channel_name) != ch:
		return
	if not auth.has("auth"):
		ch._failed(int(auth.get("status", 0)), str(auth.get("error", "auth failed")))
		return
	var data := {"channel": channel_name, "auth": auth.auth}
	if auth.has("channel_data"):
		data.channel_data = auth.channel_data
		ch._set_channel_data(_parse(auth.channel_data))
	_send({"event": "pusher:subscribe", "data": data})


func _authorize(channel_name: String) -> Dictionary:
	if authorizer.is_valid():
		var result: Variant = await authorizer.call(socket_id, channel_name)
		return result if result is Dictionary else {}
	if auth_endpoint.is_empty():
		return {"status": 0, "error": "set auth_endpoint or authorizer to use %s" % channel_name}
	var form := {"socket_id": socket_id, "channel_name": channel_name}
	form.merge(auth_params)
	var http := HTTPRequest.new()
	add_child(http)
	var headers := PackedStringArray(["Content-Type: application/x-www-form-urlencoded", "Accept: application/json"])
	headers.append_array(auth_headers)
	var err := http.request(auth_endpoint, headers, HTTPClient.METHOD_POST, _form(form))
	if err != OK:
		http.queue_free()
		return {"status": 0, "error": "auth request failed (%d)" % err}
	var res: Array = await http.request_completed
	http.queue_free()
	var status: int = res[1]
	var body: Variant = _parse((res[3] as PackedByteArray).get_string_from_utf8())
	if res[0] != HTTPRequest.RESULT_SUCCESS or status != 200 or not (body is Dictionary) or not body.has("auth"):
		var message := "auth endpoint returned %d" % status
		if body is Dictionary and body.has("error"):
			message = str(body.error)
		return {"status": status, "error": message}
	return body


static func _form(fields: Dictionary) -> String:
	var parts := PackedStringArray()
	for k in fields:
		parts.append("%s=%s" % [str(k).uri_encode(), str(fields[k]).uri_encode()])
	return "&".join(parts)


## Pusher sends most payloads as JSON inside a string; decode it when it is
## JSON, as pusher-js does, and keep plain strings as they are.
static func _parse(value: Variant) -> Variant:
	if typeof(value) != TYPE_STRING:
		return value
	var json := JSON.new()
	if json.parse(value) == OK:
		return json.data
	return value
