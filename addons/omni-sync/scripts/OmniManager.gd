extends Node

# Signals for UI and Arena updates
signal eos_ready()
signal eos_logged_in(puid: String)
signal eos_logged_out()
signal eos_error(context: String, message: String) 
signal lobby_updated(data: Dictionary) 

signal matchmaking_status_changed(status_text: String)
signal match_found()
signal match_started()
signal host_unavailable()
signal host_migrated(new_host_puid: String, is_local_host: bool)
signal match_ended(reason: String)

# Logging System
enum DEBUG { NONE, ERROR, INFO, ALL }
var debug_mode: DEBUG = DEBUG.INFO

# Epic Developer Portal credentials
var PRODUCT_NAME := EOSCredentials.PRODUCT_NAME
var PRODUCT_VERSION := EOSCredentials.PRODUCT_VERSION
var PRODUCT_ID := EOSCredentials.PRODUCT_ID
var SANDBOX_ID := EOSCredentials.SANDBOX_ID
var DEPLOYMENT_ID := EOSCredentials.DEPLOYMENT_ID
var CLIENT_ID := EOSCredentials.CLIENT_ID
var CLIENT_SECRET := EOSCredentials.CLIENT_SECRET
var ENCRYPTION_KEY := EOSCredentials.ENCRYPTION_KEY

const BUCKET_ID := "QUICKMATCH"
const G1_BUCKET_PREFIX := "G1WALK-V1-"
const SOCKET_NAME := "P2PSOCKET"

# Change this if you need more players ;3
const MAX_PLAYERS := 4

var match_bucket := BUCKET_ID
var match_capacity := MAX_PLAYERS
var waiting_for_eos_promotion := false

var local_puid: String = ""
var current_lobby: HLobby = null
var peer: EOSGMultiplayerPeer = null
var is_logged_in: bool = false
var is_searching: bool = false
var is_migrating_host: bool = false
var last_peer_id: int = 1
var last_saved_position: Vector2 = Vector2.ZERO
var joined_peers: Array[int] = []

# Latency tracking
var _current_latency_ms: float = -1.0
var _last_ping_time: int = 0
var _last_pong_time: int = 0
const PING_INTERVAL_MS: int = 500
const HOST_TIMEOUT_MS: int = 2500


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if "--g1-lan-host-smoke" in args or "--g1-lan-client-smoke" in args:
		return
	if args.has("--rollback-host") or args.has("--rollback-client") or args.has("--rollback-replay") or args.has("--robot-starter-smoke"):
		return
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().set_auto_accept_quit(false)

	# Godot High-Level Multiplayer signals
	multiplayer.peer_connected.connect(_on_godot_peer_connected)
	multiplayer.peer_disconnected.connect(_on_godot_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_godot_connected_to_server)
	multiplayer.connection_failed.connect(_on_godot_connection_failed)
	multiplayer.server_disconnected.connect(_on_godot_server_disconnected)

	# EOSG Callbacks setup
	if ClassDB.class_exists("IEOS"):
		var _ieos = ClassDB.instantiate("IEOS") if not Engine.has_singleton("IEOS") else Engine.get_singleton("IEOS")
		
		IEOS.auth_interface_login_status_changed.connect(_on_eos_login_status_changed)
		IEOS.lobby_interface_lobby_member_status_received_callback.connect(_on_eos_lobby_member_status_received)
		IEOS.lobby_interface_lobby_update_received_callback.connect(_on_eos_lobby_update_received)
		
		_initialize_and_login_eos()
	else:
		_report_error("Initialization", "IEOS class not found. EOS features are disabled.")


# ==============================================================================
# LOGGING HELPERS
# ==============================================================================
func _log(message: String, level: DEBUG = DEBUG.INFO) -> void:
	if debug_mode >= level:
		print("[OMNI] " + message)


func _set_status(text: String) -> void:
	# Only print UI status changes to console if debugging is set to ALL
	_log("Status: " + text, DEBUG.ALL)
	matchmaking_status_changed.emit(text)


func _report_error(context: String, text: String) -> void:
	_log("ERROR [" + context + "]: " + text, DEBUG.ERROR)
	eos_error.emit(context, text)


var _is_quitting: bool = false

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if _is_quitting:
			return
		_is_quitting = true
		_handle_quit_request()
	elif what == NOTIFICATION_APPLICATION_PAUSED:
		if current_lobby != null and current_lobby.is_owner() and not is_migrating_host:
			_proactively_handover_host()


func _handle_quit_request() -> void:
	_log("Window close request received.", DEBUG.INFO)
	# Safety watchdog: guarantee the process exits within 1.5s no matter what
	get_tree().create_timer(1.5).timeout.connect(func() -> void:
		get_tree().quit()
	)
	
	if current_lobby != null and current_lobby.is_owner() and not is_migrating_host:
		var target_member: HLobbyMember = null
		for member in current_lobby.members:
			if member.product_user_id != local_puid and not member.product_user_id.is_empty():
				target_member = member
				break
		
		if target_member != null:
			_log("Promoting member to host before quit: " + target_member.product_user_id, DEBUG.INFO)
			await target_member.promote_member_async()
		
		await leave_match("Host closed game.")
	elif current_lobby != null or multiplayer.has_multiplayer_peer():
		await leave_match("Closed game.")
	
	get_tree().quit()


func _proactively_handover_host() -> void:
	if current_lobby == null or not current_lobby.is_owner() or is_migrating_host:
		return
	for member in current_lobby.members:
		if member.product_user_id != local_puid and not member.product_user_id.is_empty():
			_log("App paused/closing as host. Handing over lobby to: " + member.product_user_id, DEBUG.INFO)
			await member.promote_member_async()
			leave_match("App paused. Lobby handed over.")
			break


func _process(_delta: float) -> void:
	if get_tree().has_meta("g1_lan"):
		return
	if not is_logged_in or not multiplayer.has_multiplayer_peer():
		return
	if multiplayer.is_server():
		return
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return

	var now := Time.get_ticks_msec()
	if now - _last_ping_time >= PING_INTERVAL_MS:
		_last_ping_time = now
		_ping_host.rpc_id(1, now)

	# A stalled G1 heartbeat can occur while the host loads two robots.
	# Only transport or EOS lobby events initiate G1 migration.
	if not match_bucket.begins_with(G1_BUCKET_PREFIX) and not is_migrating_host and not waiting_for_eos_promotion and _last_pong_time > 0 and (now - _last_pong_time) >= HOST_TIMEOUT_MS:
		_log("Host unresponsive (%d ms). Migrating host..." % (now - _last_pong_time), DEBUG.INFO)
		_set_status("Host connection lost. Migrating host...")
		_handle_host_loss()


# ==============================================================================
# 1. EOS BOOTSTRAPPING & ADVANCED STATES
# ==============================================================================
func _initialize_and_login_eos() -> void:
	_set_status("Initializing network services...")

	var creds := HCredentials.new()
	creds.product_name = PRODUCT_NAME
	creds.product_version = PRODUCT_VERSION
	creds.product_id = PRODUCT_ID
	creds.sandbox_id = SANDBOX_ID
	creds.deployment_id = DEPLOYMENT_ID
	creds.client_id = CLIENT_ID
	creds.client_secret = CLIENT_SECRET
	creds.encryption_key = ENCRYPTION_KEY

	var setup_ok: bool = await HPlatform.setup_eos_async(creds)
	if not setup_ok:
		_report_error("EOS Setup", "Failed to initialize EOS Platform.")
		_set_status("Failed to initialize.")
		return

	_set_status("Logging in anonymously via Device ID...")
	var device_alias := "Player_" + str(randi() % 9000 + 1000)
	var login_ok: bool = await HAuth.login_anonymous_async(device_alias)
	
	if not login_ok:
		_report_error("Login", "Anonymous Device ID login failed.")
		_set_status("Login failed.")
		return

	local_puid = HAuth.product_user_id
	is_logged_in = true
	_log("Logged in successfully. PUID: " + local_puid, DEBUG.INFO)
	
	eos_ready.emit()
	eos_logged_in.emit(local_puid)
	_set_status("Online & Ready (" + HAuth.display_name + ")")


func _on_eos_login_status_changed(data: Dictionary) -> void:
	var status: int = data.get("current_status", -1)
	
	if status == 2: # LoggedIn
		if not is_logged_in:
			is_logged_in = true
			eos_logged_in.emit(local_puid)
	elif status == 0: # NotLoggedIn
		_log("Auth session expired.", DEBUG.ERROR)
		is_logged_in = false
		eos_logged_out.emit()
		_report_error("Auth", "Session expired or disconnected.")
		if current_lobby != null:
			leave_match("EOS Session disconnected.")


# ==============================================================================
# 2. AUTOMATIC QUICK MATCHMAKING
# ==============================================================================
func search_for_match(bucket: String = BUCKET_ID, capacity: int = MAX_PLAYERS, join_only := false, host_only := false) -> void:
	if not is_logged_in or is_searching:
		return
	is_searching = true
	match_bucket = bucket
	match_capacity = capacity
	_set_status("Searching for an open match...")
	_log("Searching for open lobbies in bucket: " + match_bucket, DEBUG.INFO)

	if current_lobby != null:
		if current_lobby.is_owner():
			await current_lobby.destroy_async()
		else:
			await current_lobby.leave_async()
		current_lobby = null

	if not host_only:
		await get_tree().create_timer(randf_range(0.15, 0.55)).timeout

		var lobbies: Array = await HLobbies.search_by_bucket_id_async(match_bucket)
		if lobbies == null:
			_report_error("Matchmaking", "Search failed. Check network connection.")
			is_searching = false
			_set_status("Matchmaking failed.")
			return

		var joinable_lobbies: Array[HLobby] = []
		for lobby: HLobby in lobbies:
			_log("Found lobby: id=%s, owner=%s, slots=%d, members=%d" % [lobby.lobby_id, lobby.owner_product_user_id, lobby.available_slots, lobby.members.size()], DEBUG.INFO)
			if not local_puid.is_empty() and lobby.owner_product_user_id == local_puid:
				_log("Skipping own lobby", DEBUG.INFO)
				continue
			if lobby.available_slots > 0 and lobby.members.size() < match_capacity:
				joinable_lobbies.append(lobby)

		if not joinable_lobbies.is_empty():
			var random_lobby: HLobby = joinable_lobbies.pick_random()
			_set_status("Match found! Joining...")
			_log("Joining lobby: " + random_lobby.lobby_id, DEBUG.INFO)

			# Prefer join_async since random_lobby has the search details handle
			var joined_lobby: HLobby = await HLobbies.join_async(random_lobby)
			if joined_lobby == null:
				joined_lobby = await HLobbies.join_by_id_async(random_lobby.lobby_id)

			if joined_lobby != null:
				current_lobby = joined_lobby
				match_found.emit()
				_setup_client_peer(current_lobby.owner_product_user_id)
				is_searching = false
				return
			else:
				_report_error("Matchmaking", "Failed to join found lobby.")

	if join_only:
		is_searching = false
		_set_status("No open match found. Start a host first, then try Join again.")
		return

	_set_status("Creating new match as Host...")
	_log("No lobbies found. Creating a new one...", DEBUG.INFO)
	
	var create_opts := EOS.Lobby.CreateLobbyOptions.new()
	create_opts.bucket_id = match_bucket
	create_opts.max_lobby_members = match_capacity
	create_opts.permission_level = EOS.Lobby.LobbyPermissionLevel.PublicAdvertised
	create_opts.allow_invites = true
	create_opts.enable_join_by_id = true
	create_opts.enable_rtc_room = false
	create_opts.disable_host_migration = false

	var new_lobby: HLobby = await HLobbies.create_lobby_async(create_opts)
	if new_lobby == null:
		_report_error("Matchmaking", "Lobby creation rejected by backend.")
		is_searching = false
		_set_status("Failed to create lobby. Try again.")
		return

	current_lobby = new_lobby
	match_found.emit() # Target for scene transition to loading screen
	_setup_host_peer()
	is_searching = false


# ==============================================================================
# 3. EOSG MULTIPLAYER PEER (HOST & CLIENT SETUP)
# ==============================================================================
func _setup_host_peer() -> void:
	if peer != null:
		peer.close()

	peer = EOSGMultiplayerPeer.new()
	var err := peer.create_server(SOCKET_NAME)
	if err != OK:
		_report_error("Server", "Failed to create EOS Server Peer: " + str(err))
		_set_status("Server creation error.")
		return

	multiplayer.multiplayer_peer = peer
	joined_peers.clear()
	joined_peers.append(1)
	
	is_searching = false
	_log("P2P Server created on socket: " + SOCKET_NAME, DEBUG.INFO)
	_set_status("Match hosted!")
	if not is_migrating_host:
		_trigger_match_start()


func _setup_client_peer(host_puid: String) -> void:
	if peer != null:
		peer.close()

	peer = EOSGMultiplayerPeer.new()
	var err := peer.create_client(SOCKET_NAME, host_puid)
	if err != OK:
		_report_error("Client", "Failed to create EOS Client Peer: " + str(err))
		is_searching = false
		_set_status("Connection error.")
		return

	multiplayer.multiplayer_peer = peer
	_log("P2P Client connecting to host: " + host_puid, DEBUG.INFO)
	_set_status("Connecting to Host...")


func _on_godot_connected_to_server() -> void:
	if get_tree().has_meta("g1_lan"):
		return
	is_searching = false
	_log("Successfully connected to host P2P server.", DEBUG.INFO)
	_set_status("Connected to Host!")
	
	_last_pong_time = Time.get_ticks_msec()
	if is_migrating_host:
		is_migrating_host = false
		var host_puid: String = current_lobby.owner_product_user_id if current_lobby else ""
		host_migrated.emit(host_puid, false)
		_set_status("Host migration complete!")
	else:
		_trigger_match_start()


func _on_godot_connection_failed() -> void:
	if get_tree().has_meta("g1_lan"):
		return
	_report_error("Connection", "Timeout or rejection from host.")
	is_searching = false
	_set_status("Connection to Host failed.")
	leave_match("Connection failed.")


func _trigger_match_start() -> void:
	match_started.emit()


# ==============================================================================
# 4. PEER CONNECTIONS & SLOTS
# ==============================================================================
func _on_godot_peer_connected(id: int) -> void:
	if get_tree().has_meta("g1_lan"):
		return
	_log("Peer connected: " + str(id), DEBUG.INFO)
	if not joined_peers.has(id):
		joined_peers.append(id)


func _on_godot_peer_disconnected(id: int) -> void:
	if get_tree().has_meta("g1_lan"):
		return
	_log("Peer disconnected: " + str(id), DEBUG.INFO)
	if is_migrating_host:
		return
	joined_peers.erase(id)


func get_player_slot(peer_id: int) -> int:
	var slot: int = joined_peers.find(peer_id)
	if slot == -1:
		joined_peers.append(peer_id)
		return joined_peers.size() - 1
	return slot


# ==============================================================================
# 5. LOBBY EVENTS & HOST MIGRATION
# ==============================================================================
func _on_eos_lobby_update_received(data: Dictionary) -> void:
	if current_lobby != null and data.get("lobby_id", "") == current_lobby.lobby_id:
		lobby_updated.emit(data)


func _on_eos_lobby_member_status_received(data: Dictionary) -> void:
	if current_lobby == null or data.get("lobby_id", "") != current_lobby.lobby_id:
		return

	var current_status: int = data.get("current_status", -1)
	var target_user_id: String = data.get("target_user_id", "")

	if current_status == 4: # Promoted
		current_lobby.owner_product_user_id = target_user_id
		var departing_g1_host := match_bucket.begins_with(G1_BUCKET_PREFIX) and (
			multiplayer.has_multiplayer_peer() and multiplayer.is_server() and target_user_id != local_puid)
		if not is_migrating_host and not departing_g1_host:
			_log("Lobby ownership transferred by backend to: " + target_user_id, DEBUG.INFO)
			_execute_instant_host_migration(target_user_id)

	elif current_status == 2 or current_status == 3: # Left or Disconnected
		if target_user_id == current_lobby.owner_product_user_id and not is_migrating_host:
			_handle_host_loss()


func _on_godot_server_disconnected() -> void:
	if get_tree().has_meta("g1_lan"):
		return
	_log("P2P connection to host closed unexpectedly.", DEBUG.ERROR)
	if current_lobby != null and not is_migrating_host:
		_set_status("Host disconnected. Migrating host...")
		_handle_host_loss()
	elif not is_migrating_host:
		_set_status("Server disconnected.")
		leave_match("Server disconnected.")


func _handle_host_loss() -> void:
	if match_bucket.begins_with(G1_BUCKET_PREFIX) and current_lobby != null:
		# G1 waits for the EOS promotion callback instead of inventing an owner.
		if not waiting_for_eos_promotion:
			waiting_for_eos_promotion = true
			host_unavailable.emit()
		return
	if is_migrating_host:
		return
	if current_lobby == null:
		_report_error("Host Migration", "Host lost and no lobby found.")
		_set_status("Host lost and no lobby found.")
		leave_match("Host disconnected.")
		return

	var old_host := current_lobby.owner_product_user_id
	var candidates: Array[String] = []
	for member in current_lobby.members:
		var puid := member.product_user_id
		if not puid.is_empty() and puid != old_host:
			candidates.append(puid)

	if candidates.is_empty():
		candidates.append(local_puid)

	candidates.sort()
	var new_host_puid := candidates[0]
	
	_log("Electing new host deterministically: " + new_host_puid, DEBUG.INFO)
	current_lobby.owner_product_user_id = new_host_puid
	_execute_instant_host_migration(new_host_puid)


func _execute_instant_host_migration(new_host_puid: String) -> void:
	if is_migrating_host:
		return
	is_migrating_host = true
	waiting_for_eos_promotion = false
	_set_status("Migrating Host...")

	if multiplayer.has_multiplayer_peer():
		last_peer_id = multiplayer.get_unique_id()

	multiplayer.multiplayer_peer = null
	if peer != null:
		peer.close()
		peer = null
	_current_latency_ms = -1.0
	_last_pong_time = 0

	await get_tree().create_timer(0.15).timeout

	var am_i_new_host: bool = (new_host_puid == local_puid)
	if am_i_new_host:
		_log("I am the new host. Creating server...", DEBUG.INFO)
		_setup_host_peer()
		host_migrated.emit(new_host_puid, true)
		await get_tree().create_timer(0.5).timeout
		is_migrating_host = false
		_set_status("Host migration complete!")
	else:
		_log("Connecting to new host: " + new_host_puid, DEBUG.INFO)
		_setup_client_peer(new_host_puid)
		_set_status("Connecting to new Host...")


func leave_match(reason: String = "Left match.") -> void:
	waiting_for_eos_promotion = false
	_log("Leaving match. Reason: " + reason, DEBUG.INFO)
	is_searching = false
	is_migrating_host = false
	last_saved_position = Vector2.ZERO
	_current_latency_ms = -1.0
	_last_ping_time = 0
	_last_pong_time = 0

	var has_other_members := false
	if current_lobby != null and current_lobby.is_owner():
		for member in current_lobby.members:
			if member.product_user_id != local_puid and not member.product_user_id.is_empty():
				has_other_members = true
				await member.promote_member_async()
				break

	if peer != null:
		peer.close()
		peer = null
	multiplayer.multiplayer_peer = null
	joined_peers.clear()

	if current_lobby != null:
		var lobby_to_leave := current_lobby
		current_lobby = null
		if lobby_to_leave.is_owner() and not has_other_members:
			await lobby_to_leave.destroy_async()
		else:
			await lobby_to_leave.leave_async()

	match_ended.emit(reason)
	_set_status("Online & Ready")


# ==============================================================================
# 6. LATENCY (PING RETRIEVER)
# ==============================================================================
func get_host_latency_ms() -> int:
	if not multiplayer.has_multiplayer_peer():
		return -1
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return -1
	if multiplayer.is_server():
		return 0
	return roundi(_current_latency_ms) if _current_latency_ms >= 0.0 else -1


@rpc("any_peer", "call_remote", "reliable")
func _ping_host(client_send_time: int) -> void:
	if multiplayer.is_server():
		var sender_id := multiplayer.get_remote_sender_id()
		_pong_client.rpc_id(sender_id, client_send_time)


@rpc("any_peer", "call_remote", "reliable")
func _pong_client(client_send_time: int) -> void:
	_last_pong_time = Time.get_ticks_msec()
	var rtt := float(_last_pong_time - client_send_time)
	if _current_latency_ms < 0.0:
		_current_latency_ms = rtt
	else:
		_current_latency_ms = lerpf(_current_latency_ms, rtt, 0.25)
