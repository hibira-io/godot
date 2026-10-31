# Changelog

## 0.3.0

- `HibiraQueue`: a matchmaking queue on a presence channel, with no
  matchmaking server. Players are matched by rating and criteria, the range
  widens while they wait, they give up after a timeout, and each match moves
  into a new `HibiraRoom`. It speaks the same `client-queue-match` event as
  @hibira-io/lobby 0.2, so Godot, browser, Unity and Cocos Creator players
  wait in one queue.
- `HibiraMatch`: the matching rules on their own (`find_matches`,
  `allowed_range`, `criteria_fit`).

## 0.2.1

- `HibiraSync` splits its batches below 4 KB, the Free plan's limit for an
  event's data. Before, a scene syncing many nodes could send a batch the
  server refused.
- README: setting up the app (where the key is, client events, allowed
  origins for web exports) and the per-plan event size.

## 0.2.0

- `Hibira` autoload and **Project Settings → Hibira** (app key, host, auth
  endpoint, auto connect, sync rate): connect with no code.
- `HibiraSync`: syncs properties of a node from its owner to every other
  player on a presence channel, batched into one client event per tick,
  changed values only, smoothed on arrival.
- Demo scene `addons/hibira/demo/playground.tscn`, which runs with no setup on
  Hibira's demo app, or on your app from Project Settings. Also
  [on the web](https://demos.hibira.io/godot/).

## 0.1.0

First release.

- `HibiraClient`: Pusher Channels protocol v7 over `WebSocketPeer`; public,
  private and presence channels signed through `auth_endpoint` or
  `authorizer`; client events; pings both ways; reconnects with backoff and
  subscribes again.
- `HibiraChannel`: `bind`/`trigger`, presence members and signals.
- `HibiraRoom`: game rooms compatible with `@hibira-io/lobby` 0.1.
