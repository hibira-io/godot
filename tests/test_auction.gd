extends SceneTree
# Offline tests for HibiraAuctionHouse.
#
#   godot --headless --import && godot --headless --script res://tests/test_auction.gd

const FakeClient := preload("res://tests/fake_client.gd")
const CH := "auction-main"
const NOW := 1_000_000.0

var failures := 0
var checks := 0


func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("FAIL: ", what)


func _initialize() -> void:
	await process_frame
	await test_snapshot_and_events()
	await test_reload_merges()
	await test_prices_and_closed()
	await test_load_failure()
	print("%d checks, %d failed" % [checks, failures])
	quit(1 if failures > 0 else 0)


func listing(id: String, version: int, extra := {}) -> Dictionary:
	var l := {"id": id, "house": "main", "sellerId": "s", "item": {"type": "bow"}, "startPrice": 10, "buyout": null,
		"price": null, "bidderId": null, "bids": 0, "minBid": 10, "endsAt": NOW + 60_000, "status": "open", "version": version}
	l.merge(extra, true)
	return l


func new_client() -> FakeClient:
	var c := FakeClient.new()
	c.app_key = "k"
	root.add_child(c)
	c.frame("pusher:connection_established", {"socket_id": "1.1"})
	return c


func open(c: FakeClient, snap: Variant) -> HibiraAuctionHouse:
	var box := {"snap": snap}
	var house := HibiraAuctionHouse.open_with(c, "main", func() -> Variant: return box.snap)
	house._now_ms = func() -> float: return NOW
	house.set_meta("box", box)
	return house


func test_snapshot_and_events() -> void:
	var c := new_client()
	var house := open(c, JSON.stringify({"house": "main", "serverNow": NOW + 2000, "listings": [listing("a", 1), listing("b", 1, {"endsAt": NOW + 10_000})], "closed": [], "prices": {}}))
	var got := {"ready": 0, "changed": 0, "updated": []}
	house.ready.connect(func(): got.ready += 1)
	house.changed.connect(func(): got.changed += 1)
	house.updated.connect(func(kind, l): got.updated.append([kind, l.id]))
	await process_frame
	check(c.last("pusher:subscribe") != null and c.last("pusher:subscribe").data.channel == CH, "subscribes to auction-main")
	c.frame("pusher_internal:subscription_succeeded", {}, CH)
	await process_frame
	check(house.is_ready and got.ready == 1, "ready after the snapshot")
	check(house.listings().map(func(l): return l.id) == ["b", "a"], "ending soonest first")
	check(house.offset_ms == 2000.0, "clock offset from serverNow")
	check(is_equal_approx(house.time_left(house.get_listing("b")), 8.0), "time left on the server clock")

	c.frame(HibiraAuctionHouse.EVENT_UPDATE, {"kind": "bid", "serverNow": NOW, "listing": listing("a", 2, {"price": 12, "bids": 1, "minBid": 13})}, CH)
	check(float(house.get_listing("a").price) == 12.0 and got.updated == [["bid", "a"]], "bid applied")
	check(house.offset_ms == 0.0, "clock offset follows events")
	c.frame(HibiraAuctionHouse.EVENT_UPDATE, {"kind": "bid", "listing": listing("a", 1)}, CH)
	check(float(house.get_listing("a").version) == 2.0 and got.updated.size() == 1, "older version ignored")
	c.frame(HibiraAuctionHouse.EVENT_UPDATE, {"kind": "listed", "listing": listing("c", 1)}, CH)
	check(house.listings().size() == 3, "new listing added")
	c.frame(HibiraAuctionHouse.EVENT_UPDATE, {"kind": "sold", "listing": listing("a", 3, {"status": "sold", "price": 12, "closedAt": NOW})}, CH)
	check(house.listings().size() == 2 and house.closed().size() == 1 and house.closed()[0].id == "a", "sold moves to closed")
	check(house.time_left(house.get_listing("a")) == 0.0, "no time left once sold")
	check(house.prices("bow").size() == 1 and house.prices("bow")[0].price == 12.0, "sale price noted")

	house.close()
	check(c.last("pusher:unsubscribe") != null, "close unsubscribes")
	c.queue_free()


func test_reload_merges() -> void:
	var c := new_client()
	var house := open(c, {"serverNow": NOW, "listings": [listing("a", 1)], "closed": []})
	c.frame("pusher_internal:subscription_succeeded", {}, CH)
	await process_frame
	# Events arrive while the next snapshot is older.
	c.frame(HibiraAuctionHouse.EVENT_UPDATE, {"kind": "bid", "listing": listing("a", 3, {"price": 20})}, CH)
	c.frame(HibiraAuctionHouse.EVENT_UPDATE, {"kind": "listed", "listing": listing("new", 1)}, CH)
	c.frame(HibiraAuctionHouse.EVENT_UPDATE, {"kind": "listed", "listing": listing("gone", 1, {"endsAt": NOW - 1000})}, CH)
	house.get_meta("box").snap = {"serverNow": NOW, "listings": [listing("a", 2)], "closed": []}
	# A reconnect subscribes again, which reloads.
	c.frame("pusher_internal:subscription_succeeded", {}, CH)
	await process_frame
	check(float(house.get_listing("a").version) == 3.0, "newer event beats an older snapshot")
	check(not house.get_listing("new").is_empty(), "listing newer than the snapshot kept")
	check(house.get_listing("gone").is_empty(), "ended listing missing from the snapshot dropped")
	house.close()
	c.queue_free()


func test_prices_and_closed() -> void:
	var c := new_client()
	var house := open(c, {"serverNow": NOW, "listings": [], "closed": [
		listing("x", 2, {"status": "sold", "price": 30, "closedAt": NOW - 100}),
		listing("y", 2, {"status": "unsold", "closedAt": NOW - 50}),
	], "prices": {"bow": [{"price": 25, "at": NOW - 5000, "listingId": "old"}, {"price": 30, "at": NOW - 100, "listingId": "x"}]}})
	house.history_per_type = 2
	c.frame("pusher_internal:subscription_succeeded", {}, CH)
	await process_frame
	check(house.closed().map(func(l): return l.id) == ["y", "x"], "closed newest first")
	check(house.prices("bow").map(func(p): return p.price) == [25.0, 30.0], "prices from the snapshot, no duplicates")
	c.frame(HibiraAuctionHouse.EVENT_UPDATE, {"kind": "sold", "listing": listing("z", 3, {"status": "sold", "price": 40, "closedAt": NOW})}, CH)
	check(house.prices("bow").map(func(p): return p.price) == [30.0, 40.0], "history trimmed to history_per_type")
	check(house.prices("sword").is_empty(), "no prices for an unknown type")
	house.close()
	c.queue_free()


func test_load_failure() -> void:
	var c := new_client()
	var house := open(c, {"error": "snapshot: HTTP 500"})
	var errors: Array = []
	house.failed.connect(func(m): errors.append(m))
	c.frame("pusher_internal:subscription_succeeded", {}, CH)
	await process_frame
	check(errors == ["snapshot: HTTP 500"] and not house.is_ready, "load failure reported")
	house.close()
	c.queue_free()
