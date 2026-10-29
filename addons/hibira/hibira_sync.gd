@icon("res://addons/hibira/icon.svg")
class_name HibiraSync
extends Node
## Keeps properties of a node in sync between players.
##
## Add it as a child of the node to sync (a player, a door, a ball), list the
## properties, and set [member channel_name] to a presence- channel. The
## player whose user id is [member owner_id] sends the values; everyone else
## receives them and, by default, moves smoothly towards them.
## [codeblock]
## # Spawning a player's avatar, local or remote:
## var avatar := AVATAR.instantiate()
## avatar.name = user_id
## var sync: HibiraSync = avatar.get_node("HibiraSync")
## sync.owner_id = user_id # who drives it
## add_child(avatar)
## [/codeblock]
## Changes are sent as client events (client-hibira-sync), batched for every
## synced node on the channel and at most [code]hibira/sync/send_rate[/code]
## times a second, so a whole scene costs one event per tick. Only changed
## values are sent, and everything again when someone joins. Values from
## anyone but the owner are ignored: the server stamps each client event
## with the sender's user id.
##
## Supported values: bool, int, float, String, Vector2/3/4, Vector2i/3i,
## Color, Quaternion, Rect2, and Arrays and Dictionaries of these.

## A value arrived from the owner (before interpolation).
signal received(values: Dictionary)
## The owner left the channel: despawn the node here.
signal owner_left

const EVENT := "client-hibira-sync"

## A presence- channel (the server stamps who sent each value there, which is
## how only the owner can move a node). Subscribed if it is not already.
@export var channel_name := ""
## User id of the player who drives this node. Empty means you: use it for
## nodes each player owns locally and spawn other players' nodes with their id.
@export var owner_id := ""
## Identifies this node on the channel. Empty: "<owner id>/<target name>".
@export var sync_id := ""
## The node whose properties are synced.
@export var target_path := NodePath("..")
## Properties of the target, e.g. "position", "rotation", "modulate", or a
## sub-property such as "modulate:a".
@export var properties := PackedStringArray(["position"])
## Move towards received values instead of jumping to them (numbers, vectors,
## colors, quaternions).
@export var interpolate := true
## How fast interpolation catches up; higher is snappier.
@export_range(1.0, 60.0) var smoothing := 15.0
## The client to use. Empty: the Hibira autoload.
@export var client_path := NodePath("")

var _client: HibiraClient
var _target: Node
var _last_sent := {} # property -> JSON of the last sent value
var _goals := {} # property -> received value, while interpolating


func _ready() -> void:
	_target = get_node_or_null(target_path)
	if _target == null:
		push_error("HibiraSync: no target at %s" % target_path)
		return
	_client = get_node_or_null(client_path) as HibiraClient if not client_path.is_empty() else get_node_or_null("/root/Hibira") as HibiraClient
	if _client == null:
		push_error("HibiraSync: no HibiraClient (turn on the Hibira plugin for the autoload, or set client_path)")
		return
	if not channel_name.begins_with("presence-") or channel_name.begins_with("presence-large-"):
		push_error("HibiraSync: channel_name must be a presence- channel, not \"%s\"" % channel_name)
		return
	_hub().add(self)


func _exit_tree() -> void:
	if _client != null and is_instance_valid(_client):
		_hub().remove(self)


## True when this player drives the node and sends its values.
func is_owner() -> bool:
	var mine := _my_id()
	return owner_id.is_empty() or (not mine.is_empty() and owner_id == mine)


## The user id that drives this node ("" until subscribed when owner_id is empty).
func resolved_owner() -> String:
	return owner_id if not owner_id.is_empty() else _my_id()


func key() -> String:
	return sync_id if not sync_id.is_empty() else "%s/%s" % [resolved_owner(), _target.name if _target else name]


## Send every value on the next tick, not only changed ones.
func resend() -> void:
	_last_sent.clear()


func _my_id() -> String:
	if _client == null:
		return ""
	var ch := _client.channel(channel_name)
	return ch.my_id if ch != null else ""


func _hub() -> HibiraSyncHub:
	return HibiraSyncHub.of(_client)


# ---- called by HibiraSyncHub -----------------------------------------------

func _collect() -> Dictionary:
	var out := {}
	if _target == null:
		return out
	for prop in properties:
		var v := encode(_target.get_indexed(NodePath(prop)))
		var j := JSON.stringify(v)
		if _last_sent.get(prop) != j:
			_last_sent[prop] = j
			out[prop] = v
	return out


func _apply(values: Dictionary) -> void:
	if _target == null:
		return
	var decoded := {}
	for prop in values:
		if not properties.has(prop):
			continue
		var v: Variant = decode(values[prop])
		decoded[prop] = v
		if interpolate and _lerpable(v) and typeof(_target.get_indexed(NodePath(prop))) == typeof(v):
			_goals[prop] = v
		else:
			_goals.erase(prop)
			_target.set_indexed(NodePath(prop), v)
	received.emit(decoded)


func _process(delta: float) -> void:
	if _goals.is_empty() or _target == null:
		return
	var w := 1.0 - exp(-smoothing * delta)
	for prop in _goals.keys():
		var path := NodePath(prop)
		var cur: Variant = _target.get_indexed(path)
		var goal: Variant = _goals[prop]
		var next: Variant
		if goal is Quaternion:
			next = (cur as Quaternion).slerp(goal, w)
		elif goal is float and prop.ends_with("rotation"):
			next = lerp_angle(cur, goal, w)
		else:
			next = lerp(cur, goal, w)
		if _close(next, goal):
			next = goal
			_goals.erase(prop)
		_target.set_indexed(path, next)


static func _lerpable(v: Variant) -> bool:
	return v is float or v is Vector2 or v is Vector3 or v is Vector4 or v is Color or v is Quaternion


static func _close(a: Variant, b: Variant) -> bool:
	if a is float:
		return absf(a - b) < 0.0005
	if a is Quaternion:
		return (a as Quaternion).is_equal_approx(b)
	return a.is_equal_approx(b)


# ---- values on the wire ------------------------------------------------------
# JSON has no vectors, so they travel as small tagged arrays. Only plain data
# is decoded: a peer can never make this create objects.

static func encode(v: Variant) -> Variant:
	match typeof(v):
		TYPE_FLOAT:
			return snappedf(v, 0.0001)
		TYPE_VECTOR2:
			return ["V2", snappedf(v.x, 0.0001), snappedf(v.y, 0.0001)]
		TYPE_VECTOR3:
			return ["V3", snappedf(v.x, 0.0001), snappedf(v.y, 0.0001), snappedf(v.z, 0.0001)]
		TYPE_VECTOR4:
			return ["V4", v.x, v.y, v.z, v.w]
		TYPE_VECTOR2I:
			return ["V2i", v.x, v.y]
		TYPE_VECTOR3I:
			return ["V3i", v.x, v.y, v.z]
		TYPE_COLOR:
			return ["C", snappedf(v.r, 0.001), snappedf(v.g, 0.001), snappedf(v.b, 0.001), snappedf(v.a, 0.001)]
		TYPE_QUATERNION:
			return ["Q", snappedf(v.x, 0.0001), snappedf(v.y, 0.0001), snappedf(v.z, 0.0001), snappedf(v.w, 0.0001)]
		TYPE_RECT2:
			return ["R2", v.position.x, v.position.y, v.size.x, v.size.y]
		TYPE_STRING_NAME:
			return String(v)
		TYPE_ARRAY:
			# A plain array is wrapped so it cannot be mistaken for a tagged value.
			return ["A", (v as Array).map(encode)]
		TYPE_DICTIONARY:
			var d := {}
			for k in v:
				d[str(k)] = encode(v[k])
			return d
	return v


static func decode(v: Variant) -> Variant:
	if v is Dictionary:
		var d := {}
		for k in v:
			d[k] = decode(v[k])
		return d
	if not (v is Array) or v.is_empty() or not (v[0] is String):
		return v
	var a: Array = v
	var n := func(i: int) -> float: return float(a[i]) if i < a.size() and (a[i] is float or a[i] is int) else 0.0
	match a[0]:
		"V2": return Vector2(n.call(1), n.call(2))
		"V3": return Vector3(n.call(1), n.call(2), n.call(3))
		"V4": return Vector4(n.call(1), n.call(2), n.call(3), n.call(4))
		"V2i": return Vector2i(int(n.call(1)), int(n.call(2)))
		"V3i": return Vector3i(int(n.call(1)), int(n.call(2)), int(n.call(3)))
		"C": return Color(n.call(1), n.call(2), n.call(3), n.call(4))
		"Q": return Quaternion(n.call(1), n.call(2), n.call(3), n.call(4))
		"R2": return Rect2(n.call(1), n.call(2), n.call(3), n.call(4))
		"A": return (a[1] as Array).map(decode) if a.size() > 1 and a[1] is Array else []
	return v
