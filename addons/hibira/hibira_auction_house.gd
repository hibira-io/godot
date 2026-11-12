class_name HibiraAuctionHouse
extends RefCounted
## An auction house run by your server with
## [url=https://github.com/hibira-io/auction-js]@hibira-io/auction[/url].
##
## Your server (createAuctionHouse in Node) checks every bid and publishes each
## change once on auction-<house>, as one auction-update event carrying the
## whole listing and a version number. This class follows that channel, keeps
## the newest version of each listing, and loads the server's snapshot
## (house.snapshot()) on every subscription, so nothing is missed after a
## reconnect. Godot, Unity and browser players share the same house.
##
## Players never bid over the socket: send bids to your own server's endpoints.
## [codeblock]
## var house := HibiraAuctionHouse.open(hibira, "main", "https://game.example/auction")
## house.changed.connect(func(): render(house.listings()))
## # every frame or so:
## label.text = "%ds" % ceili(house.time_left(listing))
## [/codeblock]
## Listings are Dictionaries with the server's keys: id, sellerId, seller,
## item, startPrice, buyout, price, bidderId, bidder, bids, minBid, endsAt (ms,
## server clock), status ("open", "sold", "unsold", "cancelled"), closedAt,
## version. JSON numbers arrive as floats.

## The first snapshot has loaded.
signal ready
## Something changed: a server event or a (re)load.
signal changed
## One server event: kind is listed, bid, extended, sold, unsold or cancelled.
signal updated(kind: String, listing: Dictionary)
## Loading the snapshot or subscribing failed.
signal failed(message: String)

const EVENT_UPDATE := "auction-update"

var channel: HibiraChannel
## The house name ("main" for auction-main).
var name: String
var is_ready := false
## The server's clock minus this device's clock, in ms.
var offset_ms := 0.0
## Closed listings kept for [method closed].
var keep_closed := 50
## Sale prices kept per item type for [method prices].
var history_per_type := 20

var _load: Callable
var _client: WeakRef
var _open := {} # id -> listing
var _closed: Array = [] # newest first
var _prices := {} # type -> [{price, at, listing_id}]
var _load_seq := 0
var _owns_subscription := false
var _now_ms := func() -> float: return Time.get_unix_time_from_system() * 1000.0


## Subscribe to auction-<house> (or [param channel_name]) and load the snapshot
## from [param snapshot_url], your server's GET that returns house.snapshot().
static func open(client: HibiraClient, house: String, snapshot_url: String, channel_name := "") -> HibiraAuctionHouse:
	var load := func() -> Variant: return await _http_get(client, snapshot_url)
	return open_with(client, house, load, channel_name)


## Like [method open], with [param load] returning the snapshot (a
## Dictionary or JSON text); it may await. Return {"error": "..."} to fail.
static func open_with(client: HibiraClient, house: String, load: Callable, channel_name := "") -> HibiraAuctionHouse:
	var ch_name := channel_name if channel_name != "" else "auction-" + house
	assert(not ch_name.begins_with("presence-"),
		"HibiraAuctionHouse: use a public or private- channel, not %s" % ch_name)
	var h := HibiraAuctionHouse.new(client, client.subscribe(ch_name), house, load)
	h._owns_subscription = true
	return h


## Track a channel you subscribed to yourself. Create it right after
## subscribing so no event is missed.
func _init(client: HibiraClient, ch: HibiraChannel, house: String, load: Callable) -> void:
	_client = weakref(client)
	channel = ch
	name = house
	_load = load
	ch.subscribed.connect(_on_subscribed)
	ch.subscription_error.connect(_on_subscription_error)
	ch.bind(EVENT_UPDATE, _on_update)
	if ch.is_subscribed():
		reload.call_deferred()


# ---- reading the house -------------------------------------------------------

## Open listings, ending soonest first.
func listings() -> Array:
	var list: Array = _open.values()
	list.sort_custom(func(a, b):
		if float(a.endsAt) != float(b.endsAt):
			return float(a.endsAt) < float(b.endsAt)
		return str(a.id) < str(b.id))
	return list


## Recently closed listings, newest first.
func closed() -> Array:
	return _closed.duplicate()


## A listing by id, open or recently closed; empty when unknown.
func get_listing(id: String) -> Dictionary:
	if _open.has(id):
		return _open[id]
	for l in _closed:
		if l.id == id:
			return l
	return {}


## The server's clock in ms since the epoch.
func now_ms() -> float:
	return _now_ms.call() + offset_ms


## Seconds left on a listing (0 once ended), on the server's clock.
func time_left(listing: Dictionary) -> float:
	if listing.is_empty() or listing.get("status", "open") != "open":
		return 0.0
	return maxf(0.0, (float(listing.endsAt) - now_ms()) / 1000.0)


## Recent sale prices of an item type, oldest first: [{price, at, listing_id}].
func prices(type: String) -> Array:
	return (_prices.get(type, []) as Array).duplicate()


## Load the snapshot again (done for you on every subscription).
func reload() -> void:
	_load_seq += 1
	var seq := _load_seq
	var result: Variant = await _load.call()
	if seq != _load_seq:
		return
	if result is String:
		result = JSON.parse_string(result)
	if not (result is Dictionary):
		failed.emit("snapshot: not a JSON object")
		return
	if result.has("error") and not result.has("listings"):
		failed.emit(str(result.error))
		return
	_merge(result)
	var first := not is_ready
	is_ready = true
	if first:
		ready.emit()
	changed.emit()


## Stop listening, and unsubscribe if [method open] subscribed.
func close() -> void:
	_load_seq += 1
	channel.unbind(EVENT_UPDATE, _on_update)
	if channel.subscribed.is_connected(_on_subscribed):
		channel.subscribed.disconnect(_on_subscribed)
	if channel.subscription_error.is_connected(_on_subscription_error):
		channel.subscription_error.disconnect(_on_subscription_error)
	if _owns_subscription:
		channel.unsubscribe()


# ---- internals ---------------------------------------------------------------

func _on_subscribed(_data: Variant) -> void:
	reload()


func _on_subscription_error(status: int, message: String) -> void:
	failed.emit("subscription failed (%d): %s" % [status, message])


func _on_update(data: Variant, _user_id: String) -> void:
	if not (data is Dictionary):
		return
	var l: Variant = data.get("listing")
	if not _valid(l):
		return
	_note_clock(data)
	var known := get_listing(str(l.id))
	if not known.is_empty() and float(known.version) >= float(l.version):
		return
	if l.get("status", "open") == "open":
		_open[l.id] = l
	else:
		_open.erase(l.id)
		_closed = _closed.filter(func(c): return c.id != l.id)
		_closed.push_front(l)
		_closed.resize(mini(_closed.size(), keep_closed))
		_note_price(l)
	updated.emit(str(data.get("kind", "")), l)
	changed.emit()


func _merge(snap: Dictionary) -> void:
	_note_clock(snap)
	var all := {}
	for l in _closed:
		all[l.id] = l
	for l in _open.values():
		all[l.id] = l
	var listed := {}
	for key in ["listings", "closed"]:
		var list: Variant = snap.get(key)
		if not (list is Array):
			continue
		for l in list:
			if not _valid(l):
				continue
			listed[l.id] = true
			if not all.has(l.id) or float(all[l.id].version) < float(l.version):
				all[l.id] = l
	# An open listing the snapshot leaves out arrived after it, unless its
	# time is up (closed and pruned on the server).
	var now := now_ms()
	for id in all.keys():
		var l: Dictionary = all[id]
		if not listed.has(id) and l.get("status", "open") == "open" and float(l.endsAt) <= now:
			all.erase(id)
	_open = {}
	var shut: Array = []
	for l in all.values():
		if l.get("status", "open") == "open":
			_open[l.id] = l
		else:
			shut.append(l)
	shut.sort_custom(func(a, b): return _num(a.get("closedAt")) > _num(b.get("closedAt")))
	shut.resize(mini(shut.size(), keep_closed))
	_closed = shut
	var p: Variant = snap.get("prices")
	if p is Dictionary:
		for type in p:
			if p[type] is Array:
				for point in p[type]:
					if point is Dictionary:
						_add_price(str(type), {"price": _num(point.get("price")), "at": _num(point.get("at")), "listing_id": str(point.get("listingId", ""))})
	for l in _closed:
		_note_price(l)


func _note_clock(d: Dictionary) -> void:
	var server_now: Variant = d.get("serverNow")
	if server_now is float or server_now is int:
		offset_ms = float(server_now) - _now_ms.call()


func _note_price(l: Dictionary) -> void:
	var item: Variant = l.get("item")
	var price: Variant = l.get("price")
	if l.get("status") != "sold" or not (item is Dictionary) or item.get("type") == null or price == null:
		return
	_add_price(str(item.type), {"price": float(price), "at": _num(l.get("closedAt")), "listing_id": str(l.id)})


func _add_price(type: String, point: Dictionary) -> void:
	var list: Array = _prices.get(type, [])
	for p in list:
		if p.listing_id == point.listing_id:
			return
	list.append(point)
	list.sort_custom(func(a, b): return a.at < b.at)
	if list.size() > history_per_type:
		list = list.slice(list.size() - history_per_type)
	_prices[type] = list


static func _valid(l: Variant) -> bool:
	return l is Dictionary and l.get("id") is String and l.id != "" and (l.get("version") is float or l.get("version") is int)


static func _num(v: Variant) -> float:
	return float(v) if v is float or v is int else 0.0


static func _http_get(client: HibiraClient, url: String) -> Variant:
	var http := HTTPRequest.new()
	client.add_child(http)
	var err := http.request(url, PackedStringArray(["Accept: application/json"]))
	if err != OK:
		http.queue_free()
		return {"error": "snapshot request failed (%d)" % err}
	var res: Array = await http.request_completed
	http.queue_free()
	if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] < 200 or res[1] >= 300:
		return {"error": "snapshot: HTTP %d" % res[1]}
	return (res[3] as PackedByteArray).get_string_from_utf8()
