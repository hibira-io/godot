# Changelog

## 0.2.0

- `Hibira` autoload and **Project Settings → Hibira** (app key, host, auth
  endpoint, auto connect, sync rate): connect with no code.
- `HibiraSync`: syncs properties of a node from its owner to every other
  player on a presence channel, batched into one client event per tick,
  changed values only, smoothed on arrival.
- Demo scene `addons/hibira/demo/playground.tscn`, which runs with no setup on
  Hibira's demo app, or on your app from Project Settings. Also
  [on the web](https://hibira-io.github.io/godot/).

## 0.1.0

First release.

- `HibiraClient`: Pusher Channels protocol v7 over `WebSocketPeer`; public,
  private and presence channels signed through `auth_endpoint` or
  `authorizer`; client events; pings both ways; reconnects with backoff and
  subscribes again.
- `HibiraChannel`: `bind`/`trigger`, presence members and signals.
- `HibiraRoom`: game rooms compatible with `@hibira-io/lobby` 0.1.
