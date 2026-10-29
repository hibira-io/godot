class_name HibiraSyncHub
extends Node
## Batches the HibiraSync nodes of one HibiraClient: one client event per
## channel per tick for everything you own, and incoming values routed to the
## right node. Created on demand as a child of the client; you rarely need it.

const NAME := "HibiraSyncHub"

var _client: HibiraClient
var _syncs := {} # channel name -> Array[HibiraSync]
var _bound := {} # channel name -> HibiraChannel the handlers are bound to
var _timer: Timer


static func of(client: HibiraClient) -> HibiraSyncHub:
	var hub := client.get_node_or_null(NAME) as HibiraSyncHub
	if hub == null:
		hub = HibiraSyncHub.new()
		hub.name = NAME
		hub._client = client
		client.add_child(hub)
	return hub


func _ready() -> void:
	_timer = Timer.new()
	_timer.wait_time = 1.0 / clampf(float(HibiraSettings.get_value("hibira/sync/send_rate")), 1.0, 10.0)
	_timer.timeout.connect(flush)
	add_child(_timer)
	_timer.start()


func add(sync: HibiraSync) -> void:
	var list: Array = _syncs.get(sync.channel_name, [])
	if not list.has(sync):
		list.append(sync)
	_syncs[sync.channel_name] = list
	_bind(sync.channel_name)


func remove(sync: HibiraSync) -> void:
	var list: Array = _syncs.get(sync.channel_name, [])
	list.erase(sync)


## Send what changed now, without waiting for the next tick.
func flush() -> void:
	for channel_name in _syncs:
		var ch := _client.channel(channel_name)
		if ch == null or not ch.is_subscribed():
			continue
		var batch := {}
		var size := 0
		for sync: HibiraSync in _syncs[channel_name]:
			if not is_instance_valid(sync) or not sync.is_owner():
				continue
			var values := sync._collect()
			if values.is_empty():
				continue
			batch[sync.key()] = values
			size += JSON.stringify(values).length()
			# Client events are limited to 10 KB; split well before that.
			if size > 8000:
				ch.trigger(HibiraSync.EVENT, {"s": batch})
				batch = {}
				size = 0
		if not batch.is_empty():
			ch.trigger(HibiraSync.EVENT, {"s": batch})


func _bind(channel_name: String) -> void:
	var ch := _client.subscribe(channel_name)
	if _bound.get(channel_name) == ch:
		return
	_bound[channel_name] = ch
	ch.bind(HibiraSync.EVENT, _on_sync.bind(channel_name))
	# Newcomers get everything: resend all values on the next tick.
	ch.subscribed.connect(func(_d): _resend(channel_name))
	ch.member_added.connect(func(_id, _info): _resend(channel_name))
	ch.member_removed.connect(func(id, _info): _owner_left(channel_name, id))


func _resend(channel_name: String) -> void:
	for sync: HibiraSync in _syncs.get(channel_name, []):
		if is_instance_valid(sync):
			sync.resend()


func _owner_left(channel_name: String, user_id: String) -> void:
	for sync: HibiraSync in _syncs.get(channel_name, []).duplicate():
		if is_instance_valid(sync) and not sync.owner_id.is_empty() and sync.owner_id == user_id:
			sync.owner_left.emit()


func _on_sync(data: Variant, user_id: String, channel_name: String) -> void:
	if user_id.is_empty() or not (data is Dictionary) or not (data.get("s") is Dictionary):
		return
	var by_key := {}
	for sync: HibiraSync in _syncs.get(channel_name, []):
		if is_instance_valid(sync) and not sync.is_owner():
			by_key[sync.key()] = sync
	for k in data.s:
		var sync: HibiraSync = by_key.get(k)
		# Only the owner may move a node.
		if sync != null and sync.resolved_owner() == user_id and data.s[k] is Dictionary:
			sync._apply(data.s[k])
