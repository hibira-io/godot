class_name HibiraMatch
extends RefCounted
## The matching rules of [HibiraQueue], as static functions with no I/O.
##
## The same rules as match.js in
## [url=https://github.com/hibira-io/lobby-js]@hibira-io/lobby[/url], so a
## Godot host and a browser host group players the same way. A ticket is
## {id, joined_at, rating, criteria}: joined_at (ms since the epoch, signed by
## the auth endpoint) orders the queue; rating is a number (skill, level, MMR);
## criteria is a Dictionary such as {"mode": "duo", "region": ["hkg", "tyo"]}.
## Two tickets fit when every key they both have agrees: equal values, or
## arrays that share a value. A key only one side has is a wildcard.
##
## Rules (all optional): size (2), min_size (size), fill_after (seconds, INF),
## rating_range (INF), widen_by (0), widen_every (seconds, 5), max_range (INF),
## compatible (a Callable taking two tickets and returning bool).

const DEFAULTS := {
	"size": 2,
	"min_size": null,
	"fill_after": INF,
	"rating_range": INF,
	"widen_by": 0.0,
	"widen_every": 5.0,
	"max_range": INF,
	"compatible": null,
}


## The rating range a ticket accepts after waiting [param waited] seconds.
static func allowed_range(waited: float, rules := {}) -> float:
	var r := _rules(rules)
	var widen_by := float(r.widen_by)
	var widen_every := float(r.widen_every)
	var steps := 0.0
	if widen_by > 0 and widen_every > 0:
		steps = floorf(maxf(0.0, waited) / widen_every)
	return minf(float(r.max_range), float(r.rating_range) + steps * widen_by)


## True when two tickets' criteria agree on every key both have.
static func criteria_fit(a: Variant, b: Variant) -> bool:
	if not (a is Dictionary) or not (b is Dictionary):
		return true
	for key in a:
		if not b.has(key):
			continue
		var x: Variant = a[key]
		var y: Variant = b[key]
		if x is Array or y is Array:
			var xs: Array = x if x is Array else [x]
			var ys: Array = y if y is Array else [y]
			if not xs.any(func(v): return ys.any(func(w): return _same(v, w))):
				return false
		elif not _same(x, y):
			return false
	return true


## Group [param tickets] into matches: [{players: [ids], tickets: [...]}],
## players in queue order. Tickets are taken oldest first; each picks the
## closest-rated tickets that fit it until there are size players, or takes a
## smaller match of at least min_size once it has waited fill_after seconds.
## Tickets left over stay in the queue. [param now] is ms since the epoch.
static func find_matches(tickets: Array, rules := {}, now := -1.0) -> Array:
	var r := _rules(rules)
	if now < 0:
		now = Time.get_unix_time_from_system() * 1000.0
	var size := maxi(1, int(r.size))
	var min_size := size if r.min_size == null else clampi(int(r.min_size), 1, size)
	var queue := tickets.duplicate()
	queue.sort_custom(_before)
	var taken := {}
	var matches := []

	for anchor in queue:
		if taken.has(anchor.id):
			continue
		var waited := (now - float(anchor.joined_at)) / 1000.0
		var allowed := allowed_range(waited, r)
		var anchor_rating := _rating(anchor)
		var candidates := queue.filter(func(t): return t.id != anchor.id and not taken.has(t.id) and _fits(anchor, t, allowed, r))
		candidates.sort_custom(func(a, b):
			var da := absf(_rating(a) - anchor_rating)
			var db := absf(_rating(b) - anchor_rating)
			if da != db:
				return da < db
			return _before(a, b))

		# Every pair in the group must fit, not only each player and the anchor:
		# {region: "hkg"} and {region: "tyo"} can both fit an anchor with no region.
		var group := [anchor]
		for c in candidates:
			if group.size() >= size:
				break
			if group.all(func(g): return g.id == anchor.id or _fits(g, c, INF, r)):
				group.append(c)
		var enough := group.size() >= size or (waited >= float(r.fill_after) and group.size() >= min_size)
		if not enough:
			continue
		group.sort_custom(_before)
		for t in group:
			taken[t.id] = true
		matches.append({"players": group.map(func(t): return t.id), "tickets": group})
	return matches


static func _rules(rules: Dictionary) -> Dictionary:
	var r := DEFAULTS.duplicate()
	r.merge(rules, true)
	return r


static func _fits(a: Dictionary, b: Dictionary, allowed: float, r: Dictionary) -> bool:
	if absf(_rating(a) - _rating(b)) > allowed:
		return false
	if not criteria_fit(a.get("criteria"), b.get("criteria")):
		return false
	var compatible: Variant = r.compatible
	if compatible is Callable and (compatible as Callable).is_valid():
		return compatible.call(a, b) != false
	return true


static func _rating(t: Dictionary) -> float:
	var v: Variant = t.get("rating")
	if (v is float or v is int) and is_finite(float(v)):
		return float(v)
	return 0.0


static func _before(a: Dictionary, b: Dictionary) -> bool:
	if float(a.joined_at) != float(b.joined_at):
		return float(a.joined_at) < float(b.joined_at)
	return str(a.id) < str(b.id)


# JSON numbers arrive as floats; compare numbers by value and everything else
# only with values of the same type.
static func _same(x: Variant, y: Variant) -> bool:
	var xn := x is float or x is int
	var yn := y is float or y is int
	if xn or yn:
		return xn and yn and float(x) == float(y)
	return typeof(x) == typeof(y) and x == y
