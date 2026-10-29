extends HibiraClient
# The Hibira autoload the plugin registers. It reads the hibira/... Project
# Settings and connects on start when hibira/connection/app_key is set and
# auto_connect is on. Use it like any HibiraClient:
#
#   Hibira.subscribe("scores").bind("updated", func(data, _u): print(data))


func _ready() -> void:
	HibiraSettings.apply(self)
	super._ready()
	if not app_key.is_empty() and HibiraSettings.get_value("hibira/connection/auto_connect"):
		connect_to_server()
