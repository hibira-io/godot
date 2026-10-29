@tool
extends EditorPlugin
# Registers the Hibira autoload and its Project Settings (hibira/...).
# HibiraClient, HibiraChannel, HibiraRoom and HibiraSync are global classes
# and work without the plugin; the plugin only adds the zero-code setup.

const AUTOLOAD := "Hibira"
const AUTOLOAD_PATH := "res://addons/hibira/hibira_autoload.gd"


func _enter_tree() -> void:
	# Settings left at their defaults are not written to project.godot; the
	# autoload reads the same defaults at runtime.
	for s in HibiraSettings.SETTINGS:
		HibiraSettings.register(s)


func _enable_plugin() -> void:
	if not ProjectSettings.has_setting("autoload/" + AUTOLOAD):
		add_autoload_singleton(AUTOLOAD, AUTOLOAD_PATH)


func _disable_plugin() -> void:
	if ProjectSettings.has_setting("autoload/" + AUTOLOAD):
		remove_autoload_singleton(AUTOLOAD)
