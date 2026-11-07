@tool
extends EditorExportPlugin

const EOS_PLUGIN_PATH = "res://addons/omni-sync"

func _get_name() -> String:
	return "EOS Android Export Helper"

func _supports_platform(platform: EditorExportPlatform) -> bool:
	if platform is EditorExportPlatformAndroid:
		return true
	return false

func _export_file(path: String, type: String, features: PackedStringArray) -> void:
	# Force include .env file in Android exports
	if path == "res://.env" and features.has("android"):
		if FileAccess.file_exists(path):
			var file = FileAccess.open(path, FileAccess.READ)
			if file:
				var content = file.get_buffer(file.get_length())
				file.close()
				add_file(path, content, false)
				print("EOS Android Export: Including .env file in export")

func _export_begin(features: PackedStringArray, is_debug: bool, path: String, flags: int) -> void:
	if not features.has("android"):
		return
	
	# Manually add .env file to export
	var env_path = "res://.env"
	if FileAccess.file_exists(env_path):
		var file = FileAccess.open(env_path, FileAccess.READ)
		if file:
			var content = file.get_buffer(file.get_length())
			file.close()
			add_file(env_path, content, false)
			print("EOS Android Export: Including .env file in export")
	else:
		push_warning("EOS Android Export: .env file not found! EOS credentials will not be available.")
		push_warning("Create res://.env with your EOS credentials for the app to work.")
	
	configure_android()

## Configures the Android build template files for EOS.
## Can be called directly on plugin activation or during export.
func configure_android() -> void:
	if not ProjectSettings.get_setting("eos_android/enable_auto_config", true):
		print("EOS Android Export: Auto-configuration disabled")
		return
	
	# Check if EOS plugin exists
	if not DirAccess.dir_exists_absolute(EOS_PLUGIN_PATH):
		push_error("EOS Android Export: Epic Online Services plugin not found at " + EOS_PLUGIN_PATH)
		push_error("Please install the Epic Online Services Godot plugin first")
		return
	
	# Check if Android build template exists
	if not DirAccess.dir_exists_absolute("res://android/build"):
		push_error("EOS Android Export: Android build template not found")
		push_error("Please install Android build template: Project -> Install Android Build Template")
		return
	
	print("EOS Android Export: Configuring Android build for EOS...")
	
	_modify_build_gradle()
	_modify_datalib_build_gradle()
	_modify_config_gradle()
	_modify_godot_app_java()
	_modify_android_manifest()
	
	print("EOS Android Export: Configuration complete")

func _modify_datalib_build_gradle() -> void:
	var file_path = "res://android/build/dataLib/build.gradle"
	if not FileAccess.file_exists(file_path):
		return
	
	var file = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		return
	
	var content = file.get_as_text()
	file.close()
	
	if not content.contains("eossdk-StaticSTDC-release.aar"):
		var deps_pos = content.find("dependencies {")
		if deps_pos != -1:
			var insert_pos = content.find("\n", deps_pos) + 1
			content = content.insert(insert_pos, "    compileOnly files('../../../addons/omni-sync/bin/android/eossdk-StaticSTDC-release.aar')\n")
			file = FileAccess.open(file_path, FileAccess.WRITE)
			if file:
				file.store_string(content)
				file.close()
				print("dataLib/build.gradle configured with EOS SDK dependency")

func _modify_build_gradle() -> void:
	var file_path = "res://android/build/build.gradle"
	var file = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		push_error("Failed to open build.gradle")
		return
	
	var content = file.get_as_text()
	file.close()
	
	var modified = false
	
	# 1. Enable core library desugaring in compileOptions
	if not content.contains("coreLibraryDesugaringEnabled"):
		var compile_pos = content.find("compileOptions {")
		if compile_pos != -1:
			var insert_pos = content.find("\n", compile_pos) + 1
			content = content.insert(insert_pos, "        coreLibraryDesugaringEnabled = true\n")
			modified = true
			print("build.gradle: Enabled coreLibraryDesugaringEnabled in compileOptions")
		else:
			push_warning("Could not find compileOptions block in build.gradle")
	elif content.contains("coreLibraryDesugaringEnabled true"):
		content = content.replace("coreLibraryDesugaringEnabled true", "coreLibraryDesugaringEnabled = true")
		modified = true
	
	# 2. Add core library desugaring dependency
	if not content.contains("desugar_jdk_libs"):
		var deps_pos = content.find("dependencies {")
		if deps_pos != -1:
			var insert_pos = content.find("\n", deps_pos) + 1
			content = content.insert(insert_pos, "    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.0.4'\n")
			modified = true
			print("build.gradle: Added coreLibraryDesugaring dependency")
		else:
			push_warning("Could not find dependencies section in build.gradle")
	
	# 3. Check if EOS SDK dependencies are already configured
	if not content.contains("// EOS SDK dependencies"):
		var deps_pos = content.find("dependencies {")
		if deps_pos == -1:
			push_error("Could not find dependencies section in build.gradle")
			return
		
		var insert_pos = content.find("\n", deps_pos) + 1
		var eos_deps = """
    // EOS SDK dependencies
    implementation 'androidx.appcompat:appcompat:1.5.1'
    implementation 'androidx.constraintlayout:constraintlayout:2.1.4'
    implementation 'androidx.security:security-crypto:1.0.0'
    implementation 'androidx.browser:browser:1.4.0'
    implementation 'androidx.webkit:webkit:1.7.0'
    implementation files('../../addons/omni-sync/bin/android/eossdk-StaticSTDC-release.aar')

"""
		content = content.insert(insert_pos, eos_deps)
		modified = true
	
	# 4. Check if protocol scheme is already configured
	if not content.contains("eos_login_protocol_scheme"):
		var config_pos = content.find("missingDimensionStrategy 'products', 'template'")
		if config_pos != -1:
			var client_id = _get_client_id()
			if not client_id.is_empty():
				var scheme_insert_pos = content.find("\n", config_pos) + 1
				var scheme_config = """
        // EOS login protocol scheme
        String ClientId = "%s"
        resValue("string", "eos_login_protocol_scheme", "eos." + ClientId.toLowerCase())

""" % client_id
				content = content.insert(scheme_insert_pos, scheme_config)
				modified = true
			else:
				push_warning("EOS Client ID not found in .env file or Credentials.gd")
	
	if modified:
		file = FileAccess.open(file_path, FileAccess.WRITE)
		if file:
			file.store_string(content)
			file.close()
			print("build.gradle configured successfully")
	else:
		print("build.gradle already configured")

func _modify_config_gradle() -> void:
	var file_path = "res://android/build/config.gradle"
	var file = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		push_error("Failed to open config.gradle")
		return
	
	var content = file.get_as_text()
	file.close()
	
	# Check and update minSdk to 23
	var min_sdk_regex = RegEx.new()
	min_sdk_regex.compile(r"minSdk\s*:\s*(\d+)")
	var result = min_sdk_regex.search(content)
	
	if result:
		var current_min_sdk = result.get_string(1).to_int()
		if current_min_sdk >= 23:
			print("config.gradle minSdk already >= 23")
			return
		
		content = min_sdk_regex.sub(content, "minSdk             : 23")
		
		file = FileAccess.open(file_path, FileAccess.WRITE)
		if file:
			file.store_string(content)
			file.close()
			print("config.gradle minSdk updated to 23")

func _modify_godot_app_java() -> void:
	# Support Godot 4.3+ modular architecture (dataLib), Godot 4.6+, and earlier paths
	var candidate_paths = [
		"res://android/build/dataLib/src/main/java/com/godot/game/GodotApp.java",
		"res://android/build/src/main/java/com/godot/game/GodotApp.java",
		"res://android/build/src/com/godot/game/GodotApp.java"
	]
	var file_path = ""
	for path in candidate_paths:
		if FileAccess.file_exists(path):
			file_path = path
			break
	
	if file_path.is_empty():
		push_error("Failed to find GodotApp.java in any known path:")
		for path in candidate_paths:
			push_error("  " + path)
		return
	
	var file = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		push_error("Failed to open GodotApp.java at " + file_path)
		return
	
	var content = file.get_as_text()
	file.close()
	
	# Check if already configured
	if content.contains("EOSSDK.init") and content.contains("onNewIntent"):
		print("GodotApp.java already configured")
		return
	
	# Add EOS and Intent imports
	var import_pattern = "import org.godotengine.godot.GodotActivity;"
	var import_pos = content.find(import_pattern)
	if import_pos != -1:
		var import_insert_pos = content.find("\n", import_pos) + 1
		var imports = """import com.epicgames.mobile.eossdk.EOSSDK;
import android.content.Intent;
import android.net.Uri;
import android.util.Log;
"""
		content = content.insert(import_insert_pos, imports)
	
	# Add static block with loadLibrary if not present
	if not content.contains("System.loadLibrary(\"EOSSDK\")"):
		var class_pattern = "public class GodotApp extends GodotActivity {"
		var class_pos = content.find(class_pattern)
		if class_pos != -1:
			var static_insert_pos = content.find("\n", class_pos) + 1
			var load_library = """\tstatic {
\t\tSystem.loadLibrary("EOSSDK");
\t}

"""
			content = content.insert(static_insert_pos, load_library)
	
	# Add EOSSDK.init in onCreate if not present
	if not content.contains("EOSSDK.init"):
		var oncreate_pattern = "public void onCreate(Bundle savedInstanceState) {"
		var oncreate_pos = content.find(oncreate_pattern)
		if oncreate_pos != -1:
			var init_insert_pos = content.find("\n", oncreate_pos) + 1
			content = content.insert(init_insert_pos, "\t\tEOSSDK.init(getActivity());\n\n")
	
	# Add onNewIntent override to handle OAuth callback
	if not content.contains("onNewIntent"):
		var last_brace = content.rfind("}")
		if last_brace != -1:
			var on_new_intent = """
\t@Override
\tprotected void onNewIntent(Intent intent) {
\t\tsuper.onNewIntent(intent);
\t\tsetIntent(intent);
\t\t
\t\t// Handle EOS OAuth deep link
\t\tUri data = intent.getData();
\t\tif (data != null) {
\t\t\tString scheme = data.getScheme();
\t\t\tif (scheme != null && scheme.startsWith("eos.")) {
\t\t\t\tLog.d("GODOT_EOS", "Received OAuth callback: " + data.toString());
\t\t\t\t// EOS SDK will automatically handle the callback
\t\t\t}
\t\t}
\t}
"""
			content = content.insert(last_brace, on_new_intent)
	
	file = FileAccess.open(file_path, FileAccess.WRITE)
	if file:
		file.store_string(content)
		file.close()
		print("GodotApp.java configured successfully at " + file_path)

func _modify_android_manifest() -> void:
	var all_manifest_paths = [
		"res://android/build/dataLib/src/main/AndroidManifest.xml",
		"res://android/build/src/main/AndroidManifest.xml",
		"res://android/build/AndroidManifest.xml"
	]
	
	# Godot 4.3+ generates src/debug/AndroidManifest.xml with singleInstancePerTask.
	# Ensure dataLib also uses singleInstancePerTask to avoid manifest merger conflicts.
	for m_path in all_manifest_paths:
		if FileAccess.file_exists(m_path):
			var m_file = FileAccess.open(m_path, FileAccess.READ)
			if m_file:
				var m_content = m_file.get_as_text()
				m_file.close()
				if m_content.contains('android:launchMode="singleTask"'):
					m_content = m_content.replace('android:launchMode="singleTask"', 'android:launchMode="singleInstancePerTask"')
					m_file = FileAccess.open(m_path, FileAccess.WRITE)
					if m_file:
						m_file.store_string(m_content)
						m_file.close()
						print("AndroidManifest: Synced launchMode to singleInstancePerTask in " + m_path)
	
	# Add OAuth intent-filter to the primary manifest declaring the launcher activity
	var primary_path = ""
	for path in all_manifest_paths:
		if FileAccess.file_exists(path):
			var test_file = FileAccess.open(path, FileAccess.READ)
			if test_file:
				var test_content = test_file.get_as_text()
				test_file.close()
				if test_content.contains("</intent-filter>") and (test_content.contains("GodotAppLauncher") or test_content.contains("android.intent.category.LAUNCHER")):
					primary_path = path
					break
	
	if primary_path.is_empty():
		return
	
	var file = FileAccess.open(primary_path, FileAccess.READ)
	if not file:
		return
	
	var content = file.get_as_text()
	file.close()
	
	if not content.contains("EOS OAuth redirect"):
		var client_id = _get_client_id()
		if client_id.is_empty():
			push_error("Cannot configure AndroidManifest without CLIENT_ID")
			return
		
		var scheme = "eos." + client_id.to_lower()
		var intent_filter_end = content.find("</intent-filter>")
		if intent_filter_end != -1:
			var insert_pos = content.find("\n", intent_filter_end) + 1
			var oauth_intent_filter = """
            <!-- EOS OAuth redirect intent filter -->
            <intent-filter>
                <action android:name="android.intent.action.VIEW" />
                <category android:name="android.intent.category.DEFAULT" />
                <category android:name="android.intent.category.BROWSABLE" />
                <data android:scheme="%s" />
            </intent-filter>
""" % scheme
			content = content.insert(insert_pos, oauth_intent_filter)
			file = FileAccess.open(primary_path, FileAccess.WRITE)
			if file:
				file.store_string(content)
				file.close()
				print("AndroidManifest.xml configured with OAuth scheme: " + scheme + " in " + primary_path)

func _get_client_id() -> String:
	# 1. Try reading from res://.env
	if FileAccess.file_exists("res://.env"):
		var file = FileAccess.open("res://.env", FileAccess.READ)
		if file:
			while not file.eof_reached():
				var line = file.get_line().strip_edges()
				if line.is_empty() or line.begins_with("#"):
					continue
				var lower_line = line.to_lower()
				if lower_line.begins_with("client_id"):
					var client_id = ""
					if ":" in line:
						var parts = line.split("=", false, 1)
						if parts.size() == 2:
							client_id = parts[1].strip_edges()
					elif "=" in line:
						var eq_pos = line.find("=")
						client_id = line.substr(eq_pos + 1).strip_edges()
					if client_id.begins_with('"') and client_id.ends_with('"'):
						client_id = client_id.substr(1, client_id.length() - 2)
					elif client_id.begins_with("'") and client_id.ends_with("'"):
						client_id = client_id.substr(1, client_id.length() - 2)
					if not client_id.is_empty():
						file.close()
						return client_id
			file.close()
	
	# 2. Fallback to res://addons/omni-sync/scripts/Credentials.gd
	var creds_path = "res://addons/omni-sync/scripts/Credentials.gd"
	if FileAccess.file_exists(creds_path):
		var file = FileAccess.open(creds_path, FileAccess.READ)
		if file:
			while not file.eof_reached():
				var line = file.get_line().strip_edges()
				if line.begins_with("const CLIENT_ID") or line.begins_with("var CLIENT_ID"):
					var parts = line.split("=", false, 1)
					if parts.size() == 2:
						var val = parts[1].strip_edges().trim_prefix(":=").strip_edges().trim_prefix("=").strip_edges()
						if val.begins_with('"') and val.ends_with('"'):
							val = val.substr(1, val.length() - 2)
						elif val.begins_with("'") and val.ends_with("'"):
							val = val.substr(1, val.length() - 2)
						if not val.is_empty():
							file.close()
							return val
			file.close()
	
	# 3. Check ProjectSettings
	var setting_val = ProjectSettings.get_setting("eos_android/client_id", "")
	if not str(setting_val).is_empty():
		return str(setting_val)
	
	push_warning("EOS Client ID not found in .env file or Credentials.gd. Please ensure CLIENT_ID is configured.")
	return ""
