class_name HibiraChannel
extends RefCounted
## A channel subscription made by [method HibiraClient.subscribe].
##
## Listen with [method bind] or the [signal event_received] signal. Presence
## channels also keep [member members] and emit [signal member_added] and
## [signal member_removed].

## The server accepted the subscription. [param data] is the presence hash
## ({"ids", "hash", "count"}) on presence channels.
signal subscribed(data: Variant)
## The auth endpoint refused the subscription (403 for a full room, say), or
## it could not be signed.
signal subscription_error(status: int, message: String)
## An event on this channel. [param user_id] is set on client events in
## presence channels: the server stamps it, so it cannot be faked.
signal event_received(event: String, data: Variant, user_id: String)
signal member_added(id: String, info: Variant)
signal member_removed(id: String, info: Variant)
## Subscriber count, when subscription_count events are turned on for the app.
signal count_changed(count: int)

var name: String
## Your presence member id (from the auth endpoint's channel_data).
var my_id := ""
## Presence members: id -> user_info.
var members := {}

var _client: WeakRef
var _subscribed := false
var _bindings := {} # event -> Array[Callable]


func _init(client: HibiraClient, channel_name: String) -> void:
	_client = weakref(client)
	name = channel_name


## True once the server has accepted the subscription (until a disconnect).
func is_subscribed() -> bool:
	return _subscribed


func is_presence() -> bool:
	return name.begins_with("presence-")


## Call [param callback] as [code]callback.call(data, user_id)[/code] for
## every [param event] on this channel.
func bind(event: String, callback: Callable) -> void:
	if not _bindings.has(event):
		_bindings[event] = []
	_bindings[event].append(callback)


## Remove one callback, or every callback for [param event].
func unbind(event: String, callback := Callable()) -> void:
	if not _bindings.has(event):
		return
	if callback.is_valid():
		_bindings[event].erase(callback)
	else:
		_bindings.erase(event)


## Send a client event to the other subscribers (not back to you). See
## [method HibiraClient.trigger].
func trigger(event: String, data: Variant) -> bool:
	var client: HibiraClient = _client.get_ref()
	if client == null or not _subscribed:
		return false
	return client.trigger(name, event, data)


func unsubscribe() -> void:
	var client: HibiraClient = _client.get_ref()
	if client != null:
		client.unsubscribe(name)


# ---- called by HibiraClient ------------------------------------------------

func _set_channel_data(data: Variant) -> void:
	if data is Dictionary and data.has("user_id"):
		my_id = str(data.user_id)


func _reset() -> void:
	_subscribed = false
	members = {}


func _failed(status: int, message: String) -> void:
	subscription_error.emit(status, message)


func _handle(event: String, data: Variant, user_id: String) -> void:
	match event:
		"pusher_internal:subscription_succeeded":
			_subscribed = true
			members = {}
			if is_presence() and data is Dictionary and data.get("presence") is Dictionary:
				var hash: Variant = data.presence.get("hash", {})
				if hash is Dictionary:
					for id in hash:
						members[str(id)] = hash[id]
				data = data.presence
			subscribed.emit(data)
			_dispatch("pusher:subscription_succeeded", data, "")
			return
		"pusher_internal:member_added":
			if data is Dictionary and data.has("user_id"):
				var id := str(data.user_id)
				var info: Variant = data.get("user_info")
				var known := members.has(id)
				members[id] = info
				if not known:
					member_added.emit(id, info)
					_dispatch("pusher:member_added", {"id": id, "info": info}, "")
			return
		"pusher_internal:member_removed":
			if data is Dictionary and data.has("user_id"):
				var id := str(data.user_id)
				if members.has(id):
					var info: Variant = members[id]
					members.erase(id)
					member_removed.emit(id, info)
					_dispatch("pusher:member_removed", {"id": id, "info": info}, "")
			return
		"pusher_internal:subscription_count":
			if data is Dictionary and data.has("subscription_count"):
				count_changed.emit(int(data.subscription_count))
			return
	if event.begins_with("pusher_internal:"):
		return
	event_received.emit(event, data, user_id)
	_dispatch(event, data, user_id)


func _dispatch(event: String, data: Variant, user_id: String) -> void:
	for cb: Callable in _bindings.get(event, []).duplicate():
		if cb.is_valid():
			cb.call(data, user_id)
