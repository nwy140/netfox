extends CenterContainer

const MATCH := "res://UnitreeG1Multiplayer.tscn"
const MENU := "res://OmniSyncMultiplayer/demo/scenes/menu.tscn"

@onready var status: Label = $Options/Status
@onready var modes: OptionButton = $Options/RelayMode
@onready var play: Button = $Options/Play


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.has("--rollback-host") or args.has("--rollback-client") or args.has("--rollback-replay"):
		get_tree().change_scene_to_file.call_deferred("res://robot_starter/SharedRollback.tscn")
		return
	$Options/Transport.add_item("EOS")
	$Options/Transport.add_item("LAN (ENet)")
	$Options/Transport.item_selected.connect(update_transport)
	multiplayer.connected_to_server.connect(on_lan_connected)
	multiplayer.connection_failed.connect(on_lan_failed)
	modes.add_item("Force EOS relay", EOS.P2P.RelayControl.ForceRelays)
	modes.add_item("Direct only", EOS.P2P.RelayControl.NoRelays)
	modes.add_item("Allow relay fallback", EOS.P2P.RelayControl.AllowRelays)
	play.pressed.connect(connect_match.bind(false))
	$Options/Host.pressed.connect(connect_match.bind(true))
	$Options/Back.pressed.connect(func() -> void: get_tree().change_scene_to_file(MENU))
	OmniManager.eos_logged_in.connect(on_login)
	OmniManager.eos_error.connect(on_error)
	OmniManager.matchmaking_status_changed.connect(on_status)
	OmniManager.match_started.connect(on_match_started)
	set_match_buttons(not OmniManager.is_logged_in)
	status.text = "Ready" if OmniManager.is_logged_in else "Waiting for EOS login"
	update_transport(0)
	if "--g1-lan-host-smoke" in args or "--g1-lan-client-smoke" in args:
		$Options/Transport.select(1)
		update_transport(1)
		connect_match.call_deferred("--g1-lan-host-smoke" in args)
	if get_tree().has_meta("g1_lobby_notice"):
		status.text = get_tree().get_meta("g1_lobby_notice")
		get_tree().remove_meta("g1_lobby_notice")


func connect_match(host: bool) -> void:
	if FileAccess.get_file_as_bytes("res://models/g1_walk/policy.bin").size() != 125616:
		status.text = "This build is missing the G1 walking policy. Re-export with the G1 asset filters."
		return
	if uses_lan():
		connect_lan(host)
		return
	var mode := modes.get_selected_id() as EOS.P2P.RelayControl
	var result := HP2P.set_relay_control(mode)
	if result != EOS.Result.Success or HP2P.get_relay_control() != mode:
		status.text = "EOS rejected the selected relay mode."
		return
	set_match_buttons(true)
	$Options/Transport.disabled = true
	$Options/Back.disabled = true
	print("G1 EOS relay setting applied: ", mode)
	OmniManager.search_for_match(OmniManager.G1_BUCKET_PREFIX + "DUAL3-" + str(mode), 2, not host, host)


func uses_lan() -> bool:
	return $Options/Transport.selected == 1


func update_transport(_index: int) -> void:
	var lan := uses_lan()
	modes.visible = not lan
	$Options/Address.visible = lan
	$Options/Port.visible = lan
	set_match_buttons(not lan and not OmniManager.is_logged_in)
	status.text = "LAN ready" if lan else ("EOS ready" if OmniManager.is_logged_in else "Waiting for EOS login")


func connect_lan(host: bool) -> void:
	var peer := ENetMultiplayerPeer.new()
	var port := int($Options/Port.value)
	var error := peer.create_server(port, 1) if host else peer.create_client($Options/Address.text.strip_edges(), port)
	if error != OK:
		status.text = "LAN connection failed: " + error_string(error)
		return
	get_tree().set_meta("g1_lan", true)
	set_match_buttons(true)
	$Options/Transport.disabled = true
	$Options/Back.disabled = true
	status.text = "Connecting to LAN host…"
	multiplayer.multiplayer_peer = peer
	if host:
		on_lan_connected()


func on_lan_connected() -> void:
	if get_tree().has_meta("g1_lan"):
		get_tree().change_scene_to_file.call_deferred(MATCH)


func on_lan_failed() -> void:
	if not get_tree().has_meta("g1_lan"):
		return
	multiplayer.multiplayer_peer = null
	get_tree().remove_meta("g1_lan")
	$Options/Transport.disabled = false
	$Options/Back.disabled = false
	set_match_buttons(false)
	status.text = "Could not connect to the LAN host."


func set_match_buttons(disabled: bool) -> void:
	play.disabled = disabled
	$Options/Host.disabled = disabled


func on_login(_puid: String) -> void:
	if OS.is_debug_build():
		var args := OS.get_cmdline_user_args()
		if "--g1-eos-host-smoke" in args or "--g1-eos-client-smoke" in args:
			connect_match.call_deferred("--g1-eos-host-smoke" in args)
	if uses_lan():
		return
	set_match_buttons(false)
	status.text = "Ready"


func on_error(context: String, message: String) -> void:
	if uses_lan():
		return
	status.text = context + " — " + message
	set_match_buttons(not OmniManager.is_logged_in)
	$Options/Back.disabled = false
	$Options/Transport.disabled = false


func on_status(message: String) -> void:
	if uses_lan():
		return
	status.text = message
	if not OmniManager.is_searching and OmniManager.current_lobby == null:
		set_match_buttons(not OmniManager.is_logged_in)
		$Options/Back.disabled = false
	$Options/Transport.disabled = false


func on_match_started() -> void:
	if uses_lan():
		return
	get_tree().change_scene_to_file(MATCH)
