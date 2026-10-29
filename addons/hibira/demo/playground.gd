extends Node2D
# Hibira playground: open this scene and press F6. Everyone in the same room
# sees each other's dots move. Open it twice (Debug > Customize Run
# Instances), or share the room code with a friend.
#
# With no setup it uses Hibira's public demo app through demo-api.hibira.io,
# which signs presence-godot-XXXX rooms only. To use your own app, set
# hibira/connection/app_key and hibira/auth/endpoint in Project Settings and
# have your endpoint sign presence-godot-* channels.
#
# What it shows: a HibiraClient, a presence channel as a room, and one
# HibiraSync per player keeping positions in sync.

const DEMO_API := "https://demo-api.hibira.io"
const AVATAR := preload("res://addons/hibira/demo/avatar.tscn")
const PREFIX := "presence-godot-"
const LETTERS := "ABCDEFGHJKLMNPQRSTUVWXYZ"

var client := HibiraClient.new()
var channel: HibiraChannel
var player := {"id": "", "name": ""}
var demo_api := DEMO_API

var _world := Node2D.new()
var _ui := {}
var _http: HTTPRequest


func _ready() -> void:
	if OS.has_environment("HIBIRA_DEMO_API"):
		demo_api = OS.get_environment("HIBIRA_DEMO_API")
	elif _web_local() and not _query("api").is_empty():
		demo_api = _query("api")
	_load_player()
	client.name = "HibiraDemoClient"
	add_child(client)
	add_child(_world)
	_http = HTTPRequest.new()
	add_child(_http)
	_build_ui()
	client.state_changed.connect(func(_s): _render_status())
	client.error.connect(func(code, message): _notice("Error %d: %s" % [code, message]))

	var own_key: String = HibiraSettings.get_value("hibira/connection/app_key")
	var own_auth: String = HibiraSettings.get_value("hibira/auth/endpoint")
	if not own_key.is_empty() and not own_auth.is_empty():
		HibiraSettings.apply(client)
		_ui.mode.text = "Your app (Project Settings)"
	else:
		# The public demo app: the Worker tells us its key and host.
		_ui.mode.text = "Hibira demo app"
		var config := await _get_json(demo_api + "/config")
		if not (config is Dictionary and config.has("key")):
			_notice("The demo server is unreachable. Set your own app in Project Settings > Hibira.")
			return
		client.app_key = config.key
		client.host = config.host
		client.port = int(config.get("port", 443))
		client.use_tls = config.get("tls", true)
		client.auth_endpoint = demo_api + "/godot/auth"
	client.auth_params = {"user_id": player.id, "name": player.name}
	client.connect_to_server()
	var room := OS.get_environment("HIBIRA_DEMO_ROOM")
	if room.is_empty():
		room = _query("room")
	_join(room if not room.is_empty() else _random_code())


func _join(code: String) -> void:
	code = code.strip_edges().to_upper()
	if RegEx.create_from_string("^[A-Z]{4}$").search(code) == null:
		_notice("A room code is four letters.")
		return
	if channel != null:
		client.unsubscribe(channel.name)
	for child in _world.get_children():
		child.queue_free()
	_notice("")
	_ui.code.text = code
	if OS.has_feature("web"):
		# ?room=CODE in the address bar, so the link can be shared.
		JavaScriptBridge.eval("history.replaceState(null, '', '?room=%s')" % code)
	channel = client.subscribe(PREFIX + code)
	channel.subscribed.connect(func(_data):
		for id in channel.members:
			_spawn(id, channel.members[id])
		_render_status())
	channel.member_added.connect(func(id, info): _spawn(id, info); _render_status())
	channel.member_removed.connect(func(_id, _info): _render_status())
	channel.subscription_error.connect(func(status, _m):
		_notice("Room %s is full (8 players)." % code if status == 403 else "Could not join the room."))
	_render_status()


func _spawn(id: String, info: Variant) -> void:
	if _world.has_node(id.validate_node_name()):
		return
	var avatar := AVATAR.instantiate()
	avatar.name = id.validate_node_name()
	avatar.mine = id == channel.my_id
	avatar.player_name = str(info.get("name", "Player")) if info is Dictionary else "Player"
	avatar.color = Color.from_hsv(float(absi(hash(id)) % 360) / 360.0, 0.6, 0.95)
	var sync: HibiraSync = avatar.get_node("HibiraSync")
	sync.channel_name = channel.name
	sync.owner_id = id
	sync.client_path = client.get_path()
	if avatar.mine:
		var area := get_viewport_rect().size
		avatar.position = Vector2(randf_range(60, area.x - 60), randf_range(120, area.y - 60))
	else:
		# Hidden until its owner's first position arrives.
		avatar.visible = false
		sync.received.connect(func(_v): avatar.visible = true, CONNECT_ONE_SHOT)
	sync.owner_left.connect(avatar.queue_free)
	_world.add_child(avatar)


# ---- small helpers -----------------------------------------------------------

# A query parameter of the page in a web export ("" elsewhere).
static func _query(param: String) -> String:
	if not OS.has_feature("web"):
		return ""
	var v: Variant = JavaScriptBridge.eval("new URLSearchParams(location.search).get(%s) || ''" % JSON.stringify(param))
	return str(v) if v != null else ""


# A web export served from this machine, for testing against a local demo-api.
static func _web_local() -> bool:
	return OS.has_feature("web") and str(JavaScriptBridge.eval("location.hostname")) in ["localhost", "127.0.0.1"]


func _get_json(url: String) -> Variant:
	if _http.request(url) != OK:
		return null
	var res: Array = await _http.request_completed
	if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] != 200:
		return null
	return JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())


func _load_player() -> void:
	# A new player every run, so two windows or browser tabs are two players.
	player.id = "godot-" + Crypto.new().generate_random_bytes(6).hex_encode()
	player.name = "Player %d" % (randi() % 900 + 100)


static func _random_code() -> String:
	var s := ""
	for i in 4:
		s += LETTERS[randi() % LETTERS.length()]
	return s


func _notice(text: String) -> void:
	_ui.notice.text = text


func _render_status() -> void:
	var states := ["Offline", "Connecting…", "Connected", "Reconnecting…"]
	var who := ""
	if channel != null and channel.is_subscribed():
		who = "  ·  %d in this room" % channel.members.size()
	_ui.status.text = states[client.state] + who


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var bar := PanelContainer.new()
	bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	layer.add_child(bar)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 6 if side in ["top", "bottom"] else 12)
	bar.add_child(margin)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	margin.add_child(row)
	var title := Label.new()
	title.text = "Hibira playground"
	row.add_child(title)
	_ui.mode = Label.new()
	_ui.mode.modulate = Color(1, 1, 1, 0.55)
	row.add_child(_ui.mode)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	_ui.notice = Label.new()
	_ui.notice.modulate = Color(1, 0.8, 0.4)
	row.add_child(_ui.notice)
	_ui.status = Label.new()
	_ui.status.modulate = Color(1, 1, 1, 0.7)
	row.add_child(_ui.status)
	var room_label := Label.new()
	room_label.text = "Room"
	row.add_child(room_label)
	_ui.code = LineEdit.new()
	_ui.code.max_length = 4
	_ui.code.custom_minimum_size.x = 72
	_ui.code.tooltip_text = "Share this code; type another and press Enter to switch rooms"
	_ui.code.text_submitted.connect(func(t): _join(t); _ui.code.release_focus())
	row.add_child(_ui.code)
	var hint := Label.new()
	hint.text = "Move: arrows / WASD / click"
	hint.modulate = Color(1, 1, 1, 0.55)
	row.add_child(hint)
	_render_status()
