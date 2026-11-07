# Copyright (c) 2023-present Delano Lourenco
# https://github.com/3ddelano/epic-online-services-godot/
# MIT License
@tool
extends EditorExportPlugin

func _get_name() -> String:
	return "Epic Online Services Godot 4.2+ (EOSG)"

func _export_begin(features: PackedStringArray, is_debug: bool, path: String, flags: int):
	var target_platform = features[2]

	match target_platform:
		"windows":
			add_shared_object("res://addons/omni-sync/bin/windows/xaudio2_9redist.dll", [], "/")
			add_shared_object("res://addons/omni-sync/bin/windows/EOSSDK-Win64-Shipping.dll", [], "/")

		"linux":
			add_shared_object("res://addons/omni-sync/bin/linux/libEOSSDK-Linux-Shipping.so", [], "/")

		"macos":
			add_shared_object("res://addons/omni-sync/bin/macos/libEOSSDK-Mac-Shipping.dylib", [], "/")

		"android":
			if "arm64" in features or "arm64-v8a" in features:
				add_shared_object("res://addons/omni-sync/bin/android/arm64/libEOSSDK.so", [], "/")
			elif "x86_64" in features:
				add_shared_object("res://addons/omni-sync/bin/android/x86_64/libEOSSDK.so", [], "/")
			else:
				add_shared_object("res://addons/omni-sync/bin/android/arm64/libEOSSDK.so", [], "/")
