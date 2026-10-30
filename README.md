# Hibira Realtime for Godot

A Pusher Channels protocol client for Godot 4, written in GDScript, for
[Hibira](https://hibira.io) and other Pusher-compatible servers. No native
extension, so it runs on every platform Godot exports to, the web included.

- Public, private and presence channels
- Client events (`client-*`) between players, with the sender's `user_id`
  on presence channels
- Presence members, joins and leaves
- Reconnects with backoff and subscribes again; answers and sends pings
- A `Hibira` autoload set up in **Project Settings → Hibira**: no code to
  connect
- `HibiraSync`: add it under a node and that node's position (or any other
  properties) follows its owner on every other player's screen, smoothed
- `HibiraRoom`: game rooms with seats, a host, ready flags, settings, kick,
  start, and chat with typing indicators. It speaks the same events as
  [@hibira-io/lobby](https://github.com/hibira-io/lobby-js), so Godot and
  browser players can share a room.

Requires Godot 4.3 or later (CI runs 4.3 and 4.7).

**Try it:** the [playground](https://demos.hibira.io/godot/) is the demo
scene in this addon exported for the web. Open it in two tabs, or send the
link with its room code to a friend, and move the dots. In the editor, open
`addons/hibira/demo/playground.tscn` and press F6; it works with no setup.

For a complete game, see
[godot-lobby](https://github.com/hibira-io/examples/tree/main/godot-lobby):
rooms, chat and a reaction game that Godot and browser players can play
together.

## Install

Copy the `addons/hibira` folder from this repository (or from a
[release](https://github.com/hibira-io/godot/releases) download) into your
project's `addons/` folder, then turn it on in **Project → Project Settings →
Plugins**. Turning the plugin on adds the `Hibira` autoload and the
**Hibira** section to Project Settings. `HibiraClient`, `HibiraChannel`,
`HibiraRoom` and `HibiraSync` are global classes, so they are available as
soon as the files are in the project.

## Set up your app

In the [Hibira portal](https://hibira.io), create an app, then:

- Copy the **key** from the app's **Overview → Credentials**. The secret is
  shown once, when the app is created; keep it on your backend only.
- Turn on **Settings → Allow client events**: players send each other client
  events (`HibiraRoom`, `HibiraSync`).
- For a web export, add the page's origin (for example
  `https://yourname.itch.io`) to **Settings → Allowed origins**. The Free
  plan does not accept `*`, and an empty list blocks browsers. Native builds
  send no origin and need nothing here.

## Project Settings

The `Hibira` autoload reads the **Hibira** section of Project Settings and
connects on start when an app key is set.

| Setting | Default | |
|---|---|---|
| `hibira/connection/app_key` | | from the Hibira portal; never the secret |
| `hibira/connection/host` | `ws.hibira.io` | another Pusher-compatible server: host, port, TLS |
| `hibira/connection/port` | `443` | |
| `hibira/connection/use_tls` | `true` | |
| `hibira/connection/auto_connect` | `true` | off: call `Hibira.connect_to_server()` yourself, e.g. after login |
| `hibira/auth/endpoint` | | signs private and presence channels, see below |
| `hibira/sync/send_rate` | `8` | `HibiraSync` updates per second, 1 to 10 |

With the autoload, any script can use it directly:

```gdscript
func _ready() -> void:
	var scores := Hibira.subscribe("scores")
	scores.bind("updated", func(data, _user_id): print(data))
```

## Connect and listen

Without the autoload, or for a second connection, make a client yourself:

```gdscript
var hibira := HibiraClient.new()

func _ready() -> void:
	hibira.app_key = "your-app-key" # from the Hibira portal; never the secret
	add_child(hibira)
	hibira.connected.connect(func(socket_id): print("connected ", socket_id))
	hibira.connect_to_server()

	var scores := hibira.subscribe("scores")
	scores.bind("updated", func(data, _user_id): print(data))
```

The default host is `ws.hibira.io` on port 443 with TLS. For another
Pusher-compatible server, set `host`, `port` and `use_tls`.

Events your server sends through the HTTP API arrive with their JSON data
already decoded into Dictionaries and Arrays. JSON numbers become floats, as
everywhere in Godot.

## Private and presence channels

Your backend signs these subscriptions with the app secret, exactly as for
pusher-js, so any backend that already works with pusher-js or Laravel Echo
works here. Point the client at it:

```gdscript
hibira.auth_endpoint = "https://your-game.example/hibira/auth"
hibira.auth_headers = ["Authorization: Bearer %s" % session_token]
hibira.auth_params = {"user_id": player_id} # extra form fields, if your endpoint wants them
```

The endpoint gets a form POST with `socket_id` and `channel_name` and returns
`{"auth": "...", "channel_data": "..."}`. To sign some other way, set
`hibira.authorizer` to a function (it may `await`):

```gdscript
hibira.authorizer = func(socket_id: String, channel_name: String) -> Dictionary:
	var res = await my_api.post("/hibira/auth", {"socket_id": socket_id, "channel_name": channel_name})
	return res # {"auth": ..., "channel_data": ...}, or {} to refuse
```

Never ship the app secret in a game build: anyone can read it out of the
export.

```gdscript
var party := hibira.subscribe("presence-party-7")
party.subscribed.connect(func(_data): print("members: ", party.members))
party.member_added.connect(func(id, info): print(info.name, " joined"))
party.member_removed.connect(func(id, _info): print(id, " left"))
party.subscription_error.connect(func(status, message): print("refused: ", status, " ", message))

# Client events go to the other subscribers, not back to you. Turn on client
# events for the app in the Hibira portal (Settings → Allow client events).
party.trigger("client-emote", {"emote": "wave"})
party.bind("client-emote", func(data, user_id): show_emote(user_id, data.emote))
```

## Sync nodes

`HibiraSync` keeps properties of its parent in sync on a presence channel.
The player whose user id is `owner_id` sends them; everyone else receives
them and moves smoothly towards them. Values from anyone else are ignored,
since the server stamps each client event with its sender's user id.

```gdscript
# player.tscn: a CharacterBody2D with a HibiraSync child
# (channel_name "presence-match-1", properties ["position", "rotation"])

func spawn(user_id: String) -> void:
	var p := PLAYER.instantiate()
	p.name = user_id
	p.get_node("HibiraSync").owner_id = user_id # who drives it
	p.set_physics_process(user_id == match_channel.my_id) # only steer your own
	add_child(p)
```

- Leave `owner_id` empty for nodes each player owns locally; give other
  players' nodes their user id.
- Supported values: bool, int, float, String, Vector2/3/4, Vector2i/3i,
  Color, Quaternion, Rect2, and Arrays and Dictionaries of these.
- Every synced node on a channel goes out in one batched client event per
  tick (`hibira/sync/send_rate`), with only the values that changed, and
  everything again when someone joins. So a scene costs at most 10 events a
  second however many nodes it syncs, within Hibira's limit for client
  events.
- `received(values)` fires when values arrive, and `owner_left` when the
  owner leaves the channel, which is the moment to despawn the node.
- `HibiraSync` uses the `Hibira` autoload; set `client_path` to use another
  `HibiraClient`.

This suits casual and co-op games: positions, animations, scores. It is not
server-authoritative netcode: each player is trusted with the nodes they
own.

## Game rooms

```gdscript
var room := HibiraRoom.join(hibira, "presence-room-42", {"capacity": 4})
room.joined.connect(func(players, host): render(players))
room.members_changed.connect(func(players, _joined, _left): render(players))
room.host_changed.connect(func(host, _previous): print(host.info.name, " is the host now"))
room.message_received.connect(func(m): add_chat_line(m.info.name, m.text))
room.typing_changed.connect(func(ids): show_typing(ids))
room.started.connect(func(data, _by): start_game(data))
room.full.connect(func(_capacity): print("This room is full"))
room.kicked.connect(func(_by, _reason): leave_screen())

room.set_ready(true)
room.send("gl hf")
chat_input.text_changed.connect(func(_t): room.send_typing())

if room.is_host():
	room.set_settings({"map": "desert", "rounds": 3})
	room.start({"seed": 1234}, true) # true: only when every player is ready

room.players() # [{id, info, ready, host, me}] in seat order
room.leave()
```

Seats and the host come from the `joined_at` your auth endpoint signs into
`user_info`; `authorizeRoom()` in `@hibira-io/lobby/server` does that for Node,
and the lobby-js README shows Laravel. The rules (who may send what, what
happens when the host leaves, the capacity race) are the same as in
[@hibira-io/lobby](https://github.com/hibira-io/lobby-js#readme).

## Signals and methods

`HibiraClient`

| | |
|---|---|
| `connect_to_server()`, `disconnect_from_server()` | open, or close and stop reconnecting |
| `subscribe(name)`, `unsubscribe(name)`, `channel(name)` | channels; subscriptions survive reconnects |
| `trigger(channel, event, data)` | send a client event |
| `state_changed(state)`, `connected(socket_id)`, `disconnected(code, reason, will_reconnect)`, `error(code, message)` | connection |
| `event_received(channel, event, data, user_id)` | every event on every channel |

`HibiraChannel`: `bind(event, fn)`, `unbind(event, fn)`, `trigger(event, data)`,
`is_subscribed()`, `members`, `my_id`, and the signals `subscribed`,
`subscription_error`, `event_received`, `member_added`, `member_removed`,
`count_changed`.

Not supported yet: end-to-end encrypted channels (`private-encrypted-`) and
user sign-in (`pusher:signin`).

## Limits

Hibira's limits apply as for any client: client events are limited to 10 per
second per connection, an event's data to 4 KB on the Free plan (more on paid
plans), and presence channels hold up to 100 members. `HibiraSync` splits its
batches below 4 KB.

## Development

```sh
godot --headless --import
godot --headless --script res://tests/test_protocol.gd
godot --headless --script res://tests/test_sync.gd
```

The tests feed Pusher protocol frames to the client and check what it sends
back, with no network.

The playground is the project's main scene. To export it for the web, install
the export templates and run
`godot --headless --export-release Web build/web/index.html`; the preset
turns threads off, so it runs on any static host such as GitHub Pages.

## License

[MIT](LICENSE).
