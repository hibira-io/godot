class_name HibiraSettings
extends RefCounted
## The hibira/... Project Settings the plugin adds, and how the [code]Hibira[/code]
## autoload reads them.

const SETTINGS := [
	{"name": "hibira/connection/app_key", "type": TYPE_STRING, "default": "",
		"hint": PROPERTY_HINT_PLACEHOLDER_TEXT, "hint_string": "App key from the Hibira portal (not the secret)"},
	{"name": "hibira/connection/host", "type": TYPE_STRING, "default": "ws.hibira.io"},
	{"name": "hibira/connection/port", "type": TYPE_INT, "default": 443, "hint": PROPERTY_HINT_RANGE, "hint_string": "1,65535"},
	{"name": "hibira/connection/use_tls", "type": TYPE_BOOL, "default": true},
	{"name": "hibira/connection/auto_connect", "type": TYPE_BOOL, "default": true},
	{"name": "hibira/auth/endpoint", "type": TYPE_STRING, "default": "",
		"hint": PROPERTY_HINT_PLACEHOLDER_TEXT, "hint_string": "https://your-game.example/hibira/auth"},
	{"name": "hibira/sync/send_rate", "type": TYPE_FLOAT, "default": 8.0, "hint": PROPERTY_HINT_RANGE, "hint_string": "1,10,0.5"},
]


## Show one setting in Project Settings, with its default.
static func register(s: Dictionary) -> void:
	if not ProjectSettings.has_setting(s.name):
		ProjectSettings.set_setting(s.name, s.default)
	ProjectSettings.set_initial_value(s.name, s.default)
	ProjectSettings.add_property_info({
		"name": s.name,
		"type": s.type,
		"hint": s.get("hint", PROPERTY_HINT_NONE),
		"hint_string": s.get("hint_string", ""),
	})
	# Shown without turning on Advanced Settings.
	ProjectSettings.set_as_basic(s.name, true)


static func get_value(name: String) -> Variant:
	for s in SETTINGS:
		if s.name == name:
			return ProjectSettings.get_setting(name, s.default)
	return ProjectSettings.get_setting(name)


## Copy the connection settings onto [param client].
static func apply(client: HibiraClient) -> void:
	client.app_key = get_value("hibira/connection/app_key")
	client.host = get_value("hibira/connection/host")
	client.port = get_value("hibira/connection/port")
	client.use_tls = get_value("hibira/connection/use_tls")
	client.auth_endpoint = get_value("hibira/auth/endpoint")
