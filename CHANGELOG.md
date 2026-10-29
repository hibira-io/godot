# Changelog

## 0.1.0

First release.

- `HibiraClient`: Pusher Channels protocol v7 over `WebSocketPeer`; public,
  private and presence channels signed through `auth_endpoint` or
  `authorizer`; client events; pings both ways; reconnects with backoff and
  subscribes again.
- `HibiraChannel`: `bind`/`trigger`, presence members and signals.
- `HibiraRoom`: game rooms compatible with `@hibira-io/lobby` 0.1.
