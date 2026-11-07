extends "res://scripts/unitree_g1_walk.gd"

const LOBBY := "res://G1MultiplayerLobby.tscn"
const WalkScene = preload("res://UnitreeG1Walk.tscn")
const POSE_INTERVAL := 0.05
const CHECKPOINT_INTERVAL := 0.25
const INPUT_TIMEOUT_MS := 300
const CHECKPOINT_CHUNK_BYTES := 800
const MAX_CHECKPOINT_CHUNKS := 8

var epoch := 1
var sequence := 0
var last_checkpoint_sequence := -1
var last_input_sequence := -1
var input_sequence := 0
var remote_input := Vector3.ZERO
var input_received_ms := 0
var pose_elapsed := 0.0
var checkpoint_elapsed := 0.0
var checkpoint: Dictionary
var checkpoint_buffer := PackedByteArray()
var checkpoint_serial := -1
var checkpoint_next_chunk := 0
var checkpoint_chunks := 0
const PLAYBACK_DELAY := 0.12
const SNAPSHOT_LIMIT := 24
var pose_history := [[], []]
var playback_time := -1.0
var smoke_origins: Array[Vector3]
var smoke_host := "--g1-lan-host-smoke" in OS.get_cmdline_user_args() or "--g1-eos-host-smoke" in OS.get_cmdline_user_args()
var smoke_client := "--g1-lan-client-smoke" in OS.get_cmdline_user_args() or "--g1-eos-client-smoke" in OS.get_cmdline_user_args()
var smoke_logged_input := false
var smoke_impairment := "--g1-smoke-impaired" in OS.get_cmdline_user_args()
var last_pose_time := [-1.0, -1.0]
var pose_sequences := [-1, -1]
var second: Node3D
var active_host := false
var local_slot := 0
var returning := false
var disconnected_for := 0.0
var ready_peer := 0
var host_unavailable := false
var last_pose_received_ms := 0


func _ready() -> void:
	# NetworkTime and the client pose buffer already interpolate presentation.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	super._ready()
	if world == null or not world.is_ready():
		call_deferred("return_to_lobby", "G1 assets failed to load. Check the export includes policy.bin, XML and STL files.")
		return
	spawn_second()
	if "--g1-dual-smoke" in OS.get_cmdline_user_args():
		dual_smoke()
		return
	if not connected():
		call_deferred("return_to_lobby", "EOS connection closed before the G1 match loaded.")
		return
	active_host = multiplayer.is_server()
	if not active_host:
		local_slot = 1
		epoch = 0
	NetworkTime.on_tick.connect(on_network_tick)
	OmniManager.host_migrated.connect(on_host_migrated)
	OmniManager.host_unavailable.connect(func() -> void: host_unavailable = not active_host)
	OmniManager.match_ended.connect(on_match_ended)
	multiplayer.peer_disconnected.connect(on_peer_disconnected)
	status.text = "G1 multiplayer | waiting for host poses"


func connected() -> bool:
	return multiplayer.has_multiplayer_peer() and (
		multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED)


func _physics_process(delta: float) -> void:
	if returning:
		return
	if not connected() or OmniManager.is_migrating_host or host_unavailable:
		disconnected_for += delta
		status.text = "G1 multiplayer | waiting for host migration"
		if disconnected_for > 60.0:
			return_to_lobby("Host migration timed out.")
		return
	disconnected_for = 0.0
	if not multiplayer.is_server():
		if last_pose_received_ms == 0:
			status.text = "G1 multiplayer | syncing with host · WASD drives your G1"
		elif Time.get_ticks_msec() - last_pose_received_ms > 3000:
			status.text = "G1 multiplayer | waiting for robot updates · WASD drives your G1"
		pose_elapsed += delta
		if pose_elapsed >= POSE_INTERVAL:
			pose_elapsed = 0.0
			input_sequence += 1
			if epoch == 0:
				if input_sequence % 5 == 1:
					request_epoch.rpc_id(1)
			else:
				var intent := Vector3(0.45, 0.0, 0.0) if OS.is_debug_build() and smoke_client else keyboard_intent()
				receive_input.rpc_id(1, epoch, input_sequence, intent)


func on_network_tick(delta: float, tick: int) -> void:
	if returning or not active_host or not connected() or not multiplayer.is_server() or OmniManager.is_migrating_host:
		return
	var local := Vector3(0.25, 0.0, 0.0) if OS.is_debug_build() and smoke_host else keyboard_intent()
	var remote := remote_input if Time.get_ticks_msec() - input_received_ms <= INPUT_TIMEOUT_MS else Vector3.ZERO
	external_drive = true
	external_intent = local if local_slot == 0 else remote
	second.external_intent = local if local_slot == 1 else remote
	if OS.is_debug_build() and smoke_host and not smoke_logged_input and is_equal_approx(remote.x, 0.45):
		smoke_logged_input = true
		print("G1 INPUT PASS: separate host and client commands applied")
	advance_simulation(delta)
	second.advance_simulation(delta)
	status.text = " G1 multiplayer | host | epoch %d | %.2f s | %d contacts\n WASD: drive %s G1   P: patrol   Esc: leave " % [
		epoch, world.get_time(), world.get_ncon(), robot_color()]
	pose_elapsed += delta
	checkpoint_elapsed += delta
	if ready_peer == 0:
		pose_elapsed = POSE_INTERVAL
		checkpoint_elapsed = CHECKPOINT_INTERVAL
		return
	if pose_elapsed >= POSE_INTERVAL:
		pose_elapsed -= POSE_INTERVAL
		sequence += 1
		var stamp := tick * delta
		send_pose(0, self, stamp)
		send_pose(1, second, stamp)
	if checkpoint_elapsed >= CHECKPOINT_INTERVAL:
		checkpoint_elapsed -= CHECKPOINT_INTERVAL
		sequence += 1
		send_checkpoint()


func spawn_second() -> void:
	second = WalkScene.instantiate()
	second.name = "SecondG1"
	second.position = Vector3(0, 0, 3.5)
	second.external_drive = true
	add_child(second)
	second.set_physics_process(false)
	second.set_process_unhandled_key_input(false)
	second.get_node("Camera3D").clear_current(false)
	$Camera3D.make_current()
	for path in ["UI", "Floor", "Waypoint", "KeyLight"]:
		var decoration := second.get_node_or_null(path)
		if decoration != null:
			decoration.hide()
	var environment := second.get_node_or_null("Environment")
	if environment != null:
		environment.queue_free()
	for child in second.get_node("Robot").find_children("*", "MeshInstance3D"):
		var material: StandardMaterial3D = child.material_override.duplicate()
		material.albedo_color = material.albedo_color.lerp(Color("#e6a453"), 0.65)
		child.material_override = material


func send_pose(slot: int, robot: Node3D, stamp: float) -> void:
	var poses: Array[Transform3D] = []
	for id in robot.links:
		poses.append(robot.links[id].global_transform)
	var peer_id := ready_peer
	var packet_epoch := epoch
	var serial := sequence
	var time: float = robot.world.get_time()
	var contacts: int = robot.world.get_ncon()
	if smoke_impairment and OS.is_debug_build():
		# Simulate 100 ms of application-level delay and drop every tenth pose batch.
		if serial % 10 == 0:
			return
		await get_tree().create_timer(0.1).timeout
	if not returning and active_host and epoch == packet_epoch and ready_peer == peer_id:
		receive_pose.rpc_id(peer_id, packet_epoch, serial, slot, stamp, time, poses, contacts)


func _process(delta: float) -> void:
	if returning or second == null:
		return
	if not active_host:
		render_remote_poses(delta)
	var a: Node3D = links[world.body_id("pelvis")]
	var b: Node3D = second.links[second.world.body_id("pelvis")]
	if OS.is_debug_build() and smoke_client and playback_time >= 0.0:
		check_lan_smoke(a.global_position, b.global_position)
	var center := (a.global_position + b.global_position) * 0.5
	var zoom := maxf(1.0, a.global_position.distance_to(b.global_position) / 3.0)
	$Camera3D.look_at_from_position(center + Vector3(3.5, 3.0, 3.3) * zoom, center)


func check_lan_smoke(a: Vector3, b: Vector3) -> void:
	if smoke_origins.is_empty():
		smoke_origins.assign([a, b])
		return
	if a.distance_to(smoke_origins[0]) > 0.4 and b.distance_to(smoke_origins[1]) > 0.4:
		print("G1 %s PASS: both interpolated replicas moved" % ("LAN" if get_tree().has_meta("g1_lan") else "EOS"))
		get_tree().quit()


func render_remote_poses(delta: float) -> void:
	if pose_history[0].is_empty() or pose_history[1].is_empty():
		return
	var latest := minf(pose_history[0].back().stamp, pose_history[1].back().stamp)
	var target := latest - PLAYBACK_DELAY
	if playback_time < 0.0:
		playback_time = target
	else:
		var rate := clampf(1.0 + (target - playback_time) * 3.0, 0.8, 1.25)
		playback_time = minf(playback_time + delta * rate, latest)
	for slot in range(2):
		var samples: Array = pose_history[slot]
		while samples.size() > 2 and samples[1].stamp <= playback_time:
			samples.pop_front()
		var first: Dictionary = samples[0]
		var next: Dictionary = samples[mini(1, samples.size() - 1)]
		var weight := clampf((playback_time - first.stamp) / maxf(next.stamp - first.stamp, 0.001), 0.0, 1.0)
		var robot: Node3D = self if slot == 0 else second
		var index := 0
		for id in robot.links:
			var transform: Transform3D = first.poses[index]
			robot.links[id].global_transform = transform.interpolate_with(next.poses[index], weight)
			index += 1


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_ESCAPE:
		return_to_lobby("Left G1 match.")
	elif active_host and connected() and not OmniManager.is_migrating_host:
		# Keep simulation time monotonic for network interpolation.
		if not (event is InputEventKey and event.physical_keycode == KEY_R):
			super._unhandled_key_input(event)


@rpc("any_peer", "call_remote", "reliable")
func request_epoch() -> void:
	var sender := multiplayer.get_remote_sender_id()
	if active_host and multiplayer.is_server() and multiplayer.get_peers().has(sender):
		sync_epoch.rpc_id(sender, epoch, 1 - local_slot)


@rpc("authority", "call_remote", "reliable")
func sync_epoch(host_epoch: int, assigned_slot: int) -> void:
	if not active_host and epoch == 0 and host_epoch > 0 and assigned_slot in [0, 1]:
		local_slot = assigned_slot
		epoch = host_epoch


@rpc("any_peer", "call_remote", "unreliable")
func receive_input(packet_epoch: int, serial: int, intent: Vector3) -> void:
	var sender := multiplayer.get_remote_sender_id()
	var now := Time.get_ticks_msec()
	if not active_host or not multiplayer.is_server() or not multiplayer.get_peers().has(sender):
		return
	if packet_epoch != epoch or serial <= last_input_sequence or now - input_received_ms < 15:
		return
	if not intent.is_finite() or absf(intent.x) > 0.5 or intent.y != 0.0 or absf(intent.z) > 0.71:
		return
	ready_peer = sender
	last_input_sequence = serial
	remote_input = intent
	input_received_ms = now


@rpc("authority", "call_remote", "unreliable")
func receive_pose(packet_epoch: int, serial: int, slot: int, stamp: float, time: float,
		poses: Array[Transform3D], contacts: int) -> void:
	if active_host or packet_epoch != epoch or slot < 0 or slot >= 2:
		return
	var robot: Node3D = self if slot == 0 else second
	if serial <= pose_sequences[slot] or poses.size() != robot.links.size():
		return
	if not is_finite(time) or not is_finite(stamp) or time < last_pose_time[slot]:
		return
	for pose in poses:
		if not pose.is_finite():
			return
	var samples: Array = pose_history[slot]
	if not samples.is_empty() and stamp <= samples.back().stamp:
		return
	samples.append({"stamp": stamp, "poses": poses})
	if samples.size() > SNAPSHOT_LIMIT:
		samples.pop_front()
	last_pose_time[slot] = time
	pose_sequences[slot] = serial
	last_pose_received_ms = Time.get_ticks_msec()
	$Waypoint.hide()
	if slot == 1:
		status.text = " G1 multiplayer | client | epoch %d | %.2f s | %d contacts\n WASD: drive %s G1   Esc: leave " % [
			epoch, time, contacts, robot_color()]


func robot_color() -> String:
	return "grey" if local_slot == 0 else "gold"


func send_checkpoint() -> void:
	var bytes := var_to_bytes({"primary": capture_checkpoint(), "second": second.capture_checkpoint()})
	var count := ceili(float(bytes.size()) / CHECKPOINT_CHUNK_BYTES)
	if count > MAX_CHECKPOINT_CHUNKS:
		push_error("G1 checkpoint exceeds the transport budget.")
		return
	for index in range(count):
		var start := index * CHECKPOINT_CHUNK_BYTES
		receive_checkpoint_chunk.rpc_id(ready_peer, epoch, sequence, index, count,
			bytes.slice(start, start + CHECKPOINT_CHUNK_BYTES))


@rpc("authority", "call_remote", "reliable")
func receive_checkpoint_chunk(packet_epoch: int, serial: int, index: int, count: int,
		bytes: PackedByteArray) -> void:
	if active_host or packet_epoch != epoch or serial <= last_checkpoint_sequence:
		return
	if count < 1 or count > MAX_CHECKPOINT_CHUNKS or index < 0 or index >= count:
		return
	if bytes.is_empty() or bytes.size() > CHECKPOINT_CHUNK_BYTES:
		return
	if index == 0:
		checkpoint_serial = serial
		checkpoint_next_chunk = 0
		checkpoint_chunks = count
		checkpoint_buffer.clear()
	if serial != checkpoint_serial or index != checkpoint_next_chunk or count != checkpoint_chunks:
		return
	checkpoint_buffer.append_array(bytes)
	checkpoint_next_chunk += 1
	if checkpoint_next_chunk != count:
		return
	var state: Variant = bytes_to_var(checkpoint_buffer)
	checkpoint_buffer.clear()
	if state is Dictionary and state.get("primary") is Dictionary and state.get("second") is Dictionary:
		checkpoint = state
		last_checkpoint_sequence = serial


func on_peer_disconnected(_id: int) -> void:
	ready_peer = 0
	if not active_host:
		if get_tree().has_meta("g1_lan"):
			return_to_lobby("LAN host disconnected.")
			return
		host_unavailable = true
	remote_input = Vector3.ZERO
	last_input_sequence = -1


func on_host_migrated(_new_host: String, is_local_host: bool) -> void:
	if returning:
		return
	active_host = false
	epoch = epoch + 1 if is_local_host else 0
	host_unavailable = false
	ready_peer = 0
	sequence = 0
	pose_sequences = [-1, -1]
	last_pose_received_ms = 0
	last_checkpoint_sequence = -1
	last_input_sequence = -1
	last_pose_time = [-1.0, -1.0]
	remote_input = Vector3.ZERO
	pose_history = [[], []]
	playback_time = -1.0
	if is_local_host:
		if not connected() or not multiplayer.is_server() or checkpoint.is_empty() or not restore_pair(checkpoint):
			return_to_lobby("Host lost and no compatible G1 checkpoint was available.")
			return
		active_host = true
		refresh()
		print("G1 MIGRATION RESTORED epoch=%d tick=%d" % [epoch, ticks])
	checkpoint.clear()


func on_match_ended(reason: String) -> void:
	return_to_lobby(reason, false)


func return_to_lobby(reason: String, leave_match := true) -> void:
	if returning:
		return
	returning = true
	print(reason)
	get_tree().set_meta("g1_lobby_notice", reason)
	if get_tree().has_meta("g1_lan"):
		if multiplayer.has_multiplayer_peer():
			multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
		get_tree().remove_meta("g1_lan")
	elif leave_match:
		await OmniManager.leave_match(reason)
	get_tree().change_scene_to_file(LOBBY)


func restore_pair(state: Dictionary) -> bool:
	var original := capture_checkpoint()
	if not restore_checkpoint(state.primary):
		return false
	if not second.restore_checkpoint(state.second):
		restore_checkpoint(original)
		return false
	refresh()
	second.refresh()
	return true


func dual_smoke() -> void:
	set_process(false)
	set_physics_process(false)
	for i in range(1500):
		simulate_step()
		second.simulate_step()
	var state := {"primary": capture_checkpoint(), "second": second.capture_checkpoint()}
	var bytes := var_to_bytes(state)
	if world.get_qpos()[0] < 0.7 or second.world.get_qpos()[0] < 0.7 or bytes.size() > CHECKPOINT_CHUNK_BYTES * MAX_CHECKPOINT_CHUNKS:
		push_error("G1 DUAL FAIL: walking or transport budget")
		get_tree().quit(1)
		return
	for i in range(500):
		simulate_step()
		second.simulate_step()
	var expected := [world.capture_state(), second.world.capture_state()]
	if not restore_pair(state):
		get_tree().quit(1)
		return
	for i in range(500):
		simulate_step()
		second.simulate_step()
	if expected != [world.capture_state(), second.world.capture_state()]:
		push_error("G1 DUAL FAIL: continuation differed")
		get_tree().quit(1)
		return
	print("G1 DUAL PASS: two walking robots, both checkpoints restored, %d bytes" % bytes.size())
	get_tree().quit()
