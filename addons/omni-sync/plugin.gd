@tool
extends EditorPlugin

const AUTOLOADS: Dictionary = {
	"EnvLoader": "res://addons/omni-sync/android/env.gd",
	"EOSCreds": "res://addons/omni-sync/scripts/Credentials.gd",
	"EOSGRuntime": "res://addons/omni-sync/runtime.gd",
	"HPlatform": "res://addons/omni-sync/heos/hplatform.gd",
	"HAuth": "res://addons/omni-sync/heos/hauth.gd",
	"HAchievements": "res://addons/omni-sync/heos/hachievements.gd",
	"HFriends": "res://addons/omni-sync/heos/hfriends.gd",
	"HStats": "res://addons/omni-sync/heos/hstats.gd",
	"HLeaderboards": "res://addons/omni-sync/heos/hleaderboards.gd",
	"HLobbies": "res://addons/omni-sync/heos/hlobbies.gd",
	"HP2P": "res://addons/omni-sync/heos/hp2p.gd",
	"HSessions": "res://addons/omni-sync/heos/hsessions.gd",
	"OmniManager": "res://addons/omni-sync/scripts/OmniManager.gd",
}

var _eos_export_plugin: EditorExportPlugin
var _android_export_plugin: EditorExportPlugin

func _enter_tree() -> void:
	_register_settings()
	
	# Register export plugins
	if ResourceLoader.exists("res://addons/omni-sync/eos_export_plugin.gd"):
		_eos_export_plugin = load("res://addons/omni-sync/eos_export_plugin.gd").new()
		add_export_plugin(_eos_export_plugin)
	
	if ResourceLoader.exists("res://addons/omni-sync/android/export_plugin.gd"):
		_android_export_plugin = load("res://addons/omni-sync/android/export_plugin.gd").new()
		add_export_plugin(_android_export_plugin)
		if _android_export_plugin.has_method("configure_android"):
			_android_export_plugin.configure_android()


func _exit_tree() -> void:
	if _eos_export_plugin:
		remove_export_plugin(_eos_export_plugin)
		_eos_export_plugin = null
	
	if _android_export_plugin:
		remove_export_plugin(_android_export_plugin)
		_android_export_plugin = null


func _enable_plugin() -> void:
	for name in AUTOLOADS:
		var path: String = AUTOLOADS[name]
		if ResourceLoader.exists(path):
			if not ProjectSettings.has_setting("autoload/" + name):
				add_autoload_singleton(name, path)
				print("[OmniSync] Added Autoload: %s -> %s" % [name, path])
		else:
			push_error("[OmniSync] Could not find autoload script at: " + path)
	
	if _android_export_plugin and _android_export_plugin.has_method("configure_android"):
		_android_export_plugin.configure_android()


func _disable_plugin() -> void:
	for name in AUTOLOADS:
		if ProjectSettings.has_setting("autoload/" + name):
			remove_autoload_singleton(name)
			print("[OmniSync] Removed Autoload: %s" % name)


func _register_settings() -> void:
	if not ProjectSettings.has_setting("eos_android/enable_auto_config"):
		ProjectSettings.set_setting("eos_android/enable_auto_config", true)
		ProjectSettings.add_property_info({
			"name": "eos_android/enable_auto_config",
			"type": TYPE_BOOL,
			"hint": PROPERTY_HINT_NONE,
			"hint_string": "Automatically configure Android build files for EOS"
		})
		ProjectSettings.set_initial_value("eos_android/enable_auto_config", true)
		ProjectSettings.save()
