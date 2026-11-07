extends Node3D

const TICK_HZ := 30
const SUBSTEPS := 5
const INPUT_DELAY := 2
const PORT := 29476
const HISTORY := 90
const NAMES := ["grey", "gold", "puck"]
const MODEL := """
<mujoco model="rollback_contact">
  <option timestep="0.006666666666666667" gravity="0 0 0" integrator="implicitfast"/>
  <default><joint type="slide" damping="3"/><geom type="sphere" size="0.24" mass="1"/></default>
  <worldbody>
    <body name="grey" pos="-0.85 0 0"><joint name="gx" axis="1 0 0"/><joint name="gy" axis="0 1 0"/><geom/></body>
    <body name="gold" pos="0.85 0 0"><joint name="bx" axis="1 0 0"/><joint name="by" axis="0 1 0"/><geom/></body>
    <body name="puck" pos="0 0 0"><joint axis="1 0 0"/><joint axis="0 1 0"/><geom size="0.22" mass="0.8"/></body>
  </worldbody>
  <actuator><motor joint="gx"/><motor joint="gy"/><motor joint="bx"/><motor joint="by"/></actuator>
</mujoco>
"""

var world: MjWorld
var host := false
var smoke := false
var impaired := false
var ready_peer := 0
var input_history: Dictionary[int, Vector2]
var state_history: Dictionary[int, PackedFloat64Array]
var remote_history: Dictionary[int, Vector2]
var remote_command := Vector2.ZERO
var ack := -1
var last_confirmed := -1
var pending: Dictionary
var replay_from := -1
var replay_to := -1
var latest_tick := -1
var peak_error := 0.0
var matching_error := INF
var peak_correction := 0.0
var injection_correction := 0.0
var inject_pending := false
var position_before_replay := Vector3.ZERO
var peak_replay_us := 0
var replay_started_us := 0
var replay_count := 0
var intentional_error := false
var contact_seen := false
var latest_contact := false
var first_remote_tick := -1
var snapshot_bytes := 0
var remote_poses: Array[Dictionary]
var render_tick := -1.0
var status: Label
var bodies: Array[MeshInstance3D]
var ids: Array[int]


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	smoke = "--rollback-host" in args or "--rollback-client" in args
	impaired = "--rollback-impaired" in args
	world = MjWorld.new()
	add_child(world)
	if not world.load_model_from_string(MODEL):
		fail("MuJoCo model failed: " + world.get_last_error())
		return
	for body_name in NAMES:
		ids.append(world.body_id(body_name))
	build_arena()
	if "--rollback-replay" in args:
		replay_smoke()
		return
	NetworkTime.on_tick.connect(on_tick)
	NetworkRollback.before_loop.connect(begin_reconciliation)
	NetworkRollback.on_process_tick.connect(replay_tick)
	NetworkRollback.after_loop.connect(finish_reconciliation)
	multiplayer.connected_to_server.connect(client_connected)
	multiplayer.connection_failed.connect(func() -> void: fail("LAN connection failed."))
	multiplayer.server_disconnected.connect(func() -> void: status.text = "Host disconnected. Restart this arena to reconnect.")
	if smoke:
		var address := "127.0.0.1"
		for arg in args:
			if arg.begins_with("--rollback-address="):
				address = arg.get_slice("=", 1)
		connect_lan("--rollback-host" in args, address)


func connect_lan(as_host: bool, address: String) -> void:
	var peer := ENetMultiplayerPeer.new()
	var result := peer.create_server(PORT, 1) if as_host else peer.create_client(address, PORT)
	if result != OK:
		fail(error_string(result))
		return
	get_tree().set_meta("g1_lan", true)
	host = as_host
	multiplayer.multiplayer_peer = peer
	status.text = "Hosting on UDP %d" % PORT if host else "Connecting…"
	if host:
		print("ROLLBACK HOST READY")


func client_connected() -> void:
	hello.rpc_id(1)


@rpc("any_peer", "call_remote", "reliable")
func hello() -> void:
	var sender := multiplayer.get_remote_sender_id()
	if host and multiplayer.get_peers().has(sender):
		ready_peer = sender


func drive() -> Vector2:
	if smoke:
		return Vector2.RIGHT if host else Vector2.LEFT
	return Vector2(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		float(Input.is_physical_key_pressed(KEY_W)) - float(Input.is_physical_key_pressed(KEY_S))).limit_length()


func simulate(grey: Vector2, gold: Vector2) -> void:
	world.set_ctrl_array(PackedFloat64Array([grey.x * 3, grey.y * 3, gold.x * 3, gold.y * 3]))
	world.step(SUBSTEPS)
	world.forward()


func on_tick(delta: float, tick: int) -> void:
	if absf(delta - 1.0 / TICK_HZ) > 0.0001:
		fail("Rollback arena requires a 30 Hz Netfox clock.")
		return
	if host:
		if ready_peer == 0 or not multiplayer.get_peers().has(ready_peer):
			return
		tick -= INPUT_DELAY
		# Consume the newest command whose tick is due. Held input is part of the snapshot.
		for input_tick in remote_history.keys():
			if input_tick <= tick:
				if input_tick > ack:
					ack = input_tick
					remote_command = remote_history[input_tick]
				remote_history.erase(input_tick)
		simulate(drive(), remote_command)
		contact_seen = contact_seen or world.get_ncon() > 0
		if tick % 2 == 0:
			send_state(tick, drive())
		return
	if not multiplayer.has_multiplayer_peer() or not NetworkTime.is_initial_sync_done():
		return
	var command := drive()
	input_history[tick] = command
	input_history.erase(tick - HISTORY)
	state_history.erase(tick - HISTORY)
	send_input(tick, command)
	latest_tick = tick
	# The smoke deliberately predicts one wrong command after contact is observed.
	var predicted := command
	if smoke and latest_contact and not intentional_error:
		predicted = -command
		intentional_error = true
		inject_pending = true
		print("ROLLBACK ERROR INJECTED tick=%d" % tick)
	simulate(remote_command, predicted)
	state_history[tick] = world.capture_state()


func send_input(tick: int, command: Vector2) -> void:
	if impaired:
		if tick % 5 == 0:
			return
		await get_tree().create_timer(0.08 + float(tick % 7) * 0.005).timeout
	if multiplayer.has_multiplayer_peer():
		submit_input.rpc_id(1, tick, command)


@rpc("any_peer", "call_remote", "unreliable")
func submit_input(tick: int, command: Vector2) -> void:
	if not host or multiplayer.get_remote_sender_id() != ready_peer:
		return
	if tick <= ack or absi(tick - NetworkTime.tick) > HISTORY or not command.is_finite() or command.length_squared() > 1.001:
		return
	remote_history[tick] = command


func send_state(tick: int, grey: Vector2) -> void:
	var state := world.capture_state()
	var positions := PackedVector3Array()
	for id in ids:
		positions.append(to_godot(world.body_world_position(id)))
	var acknowledged := ack
	var contact := contact_seen
	var recipient := ready_peer
	if impaired:
		if tick % 10 == 0:
			return
		await get_tree().create_timer(0.08 + float(tick % 7) * 0.005).timeout
	if multiplayer.has_multiplayer_peer() and multiplayer.get_peers().has(recipient):
		receive_state.rpc_id(recipient, tick, acknowledged, grey, state, positions, contact)


@rpc("authority", "call_remote", "unreliable")
func receive_state(tick: int, acknowledged: int, grey: Vector2, state: PackedFloat64Array,
		positions: PackedVector3Array, contact: bool) -> void:
	if host or tick <= last_confirmed or tick <= pending.get("tick", -1) or positions.size() != 3:
		return
	pending = {"tick": tick, "ack": acknowledged, "grey": grey, "state": state}
	latest_contact = contact
	snapshot_bytes = var_to_bytes([tick, acknowledged, grey, state, positions, contact]).size()
	remote_poses.append({"tick": tick, "poses": positions})
	if remote_poses.size() > 24:
		remote_poses.pop_front()
	if first_remote_tick < 0:
		first_remote_tick = tick


func begin_reconciliation() -> void:
	if host or pending.is_empty() or latest_tick < pending.tick:
		return
	var confirmed: int = pending.tick
	if latest_tick - confirmed >= mini(HISTORY, NetworkRollback.history_limit):
		pending.clear()
		return
	position_before_replay = world.body_world_position(ids[1])
	if state_history.has(confirmed):
		var predicted: PackedFloat64Array = state_history[confirmed]
		matching_error = state_error(predicted, pending.state)
		peak_error = maxf(peak_error, matching_error)
	if not world.restore_state(pending.state):
		fail("Authoritative MuJoCo snapshot could not be restored.")
		return
	remote_command = pending.grey
	ack = pending.ack
	last_confirmed = confirmed
	replay_from = confirmed + 1
	replay_to = latest_tick
	replay_started_us = Time.get_ticks_usec()
	pending.clear()
	NetworkRollback.notify_resimulation_start(replay_from)


func replay_tick(tick: int) -> void:
	if replay_from < 0 or tick < replay_from or tick > replay_to:
		return
	simulate(remote_command, input_history.get(tick, Vector2.ZERO))
	state_history[tick] = world.capture_state()
	replay_count += 1


func finish_reconciliation() -> void:
	if replay_from < 0:
		return
	var correction := world.body_world_position(ids[1]).distance_to(position_before_replay)
	peak_correction = maxf(peak_correction, correction)
	if inject_pending:
		injection_correction = correction
		inject_pending = false
	peak_replay_us = maxi(peak_replay_us, Time.get_ticks_usec() - replay_started_us)
	replay_from = -1
	if smoke and intentional_error and last_confirmed > first_remote_tick + 90 and replay_count > 0 and ack >= 0:
		if injection_correction <= 1e-5 or matching_error > 1e-8:
			fail("Did not converge: injected correction=%f matching error=%f" % [injection_correction, matching_error])
			return
		print("ROLLBACK NET PASS contact=%s tick=%d ack=%d replays=%d peak_error=%.9f final_error=%.9f correction_m=%.6f injected_correction_m=%.6f peak_replay_us=%d snapshot_bytes=%d" % [
			latest_contact, last_confirmed, ack, replay_count, peak_error, matching_error, peak_correction,
			injection_correction, peak_replay_us, snapshot_bytes])
		get_tree().quit()


func replay_smoke() -> void:
	for i in range(8):
		simulate(Vector2.RIGHT, Vector2.LEFT)
	var initial := world.capture_state()
	var touched := false
	for i in range(36):
		simulate(Vector2.RIGHT, Vector2.LEFT)
		touched = touched or world.get_ncon() > 0
	var expected := world.capture_state()
	if not world.restore_state(initial):
		fail("Checkpoint restore failed.")
		return
	for i in range(36):
		simulate(Vector2.RIGHT, Vector2.LEFT)
	var actual := world.capture_state()
	var error := state_error(expected, actual)
	if not touched or error > 1e-9:
		fail("Replay failed: contact=%s max_error=%s" % [touched, error])
		return
	print("ROLLBACK REPLAY PASS contact=true max_error=%.12f" % error)
	get_tree().quit()


func state_error(expected: PackedFloat64Array, actual: PackedFloat64Array) -> float:
	if expected.size() != actual.size():
		return INF
	var error := 0.0
	for i in range(expected.size()):
		error = maxf(error, absf(expected[i] - actual[i]))
	return error


func _process(delta: float) -> void:
	if bodies.is_empty():
		return
	for i in range(ids.size()):
		bodies[i].position = to_godot(world.body_world_position(ids[i]))
	if not host and not remote_poses.is_empty():
		var latest: float = remote_poses.back().tick
		if render_tick < 0:
			render_tick = latest - 3.0
		render_tick = minf(latest, render_tick + delta * TICK_HZ)
		if latest - render_tick > 6:
			render_tick = latest - 3
		while remote_poses.size() > 2 and remote_poses[1].tick <= render_tick:
			remote_poses.pop_front()
		var a := remote_poses[0]
		var b := remote_poses[mini(1, remote_poses.size() - 1)]
		var weight := clampf((render_tick - a.tick) / maxf(1, b.tick - a.tick), 0, 1)
		for i in [0, 2]:
			bodies[i].position = a.poses[i].lerp(b.poses[i], weight)


func to_godot(position: Vector3) -> Vector3:
	return Vector3(position.x, position.z + 0.24, -position.y)


func build_arena() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	var camera := Camera3D.new()
	add_child(camera)
	camera.look_at_from_position(Vector3(2.5, 3.4, 4.1), Vector3.ZERO)
	camera.current = true
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -28, 0)
	add_child(light)
	var floor_mesh := BoxMesh.new()
	floor_mesh.size = Vector3(8, 0.06, 8)
	mesh_instance(floor_mesh, Color("#263442")).position.y = -0.04
	for color in [Color.SILVER, Color.GOLDENROD, Color.CORNFLOWER_BLUE]:
		var mesh := SphereMesh.new()
		mesh.radius = 0.24
		mesh.height = 0.48
		bodies.append(mesh_instance(mesh, color))
	var overlay := CanvasLayer.new()
	add_child(overlay)
	var panel := VBoxContainer.new()
	panel.position = Vector2(16, 16)
	overlay.add_child(panel)
	status = Label.new()
	status.text = "Shared MuJoCo rollback arena · WASD"
	panel.add_child(status)
	var address := LineEdit.new()
	address.text = "127.0.0.1"
	panel.add_child(address)
	for role in ["Host", "Join"]:
		var button := Button.new()
		button.text = role
		panel.add_child(button)
		button.pressed.connect(func() -> void:
			if not multiplayer.has_multiplayer_peer():
				connect_lan(role == "Host", address.text))


func mesh_instance(mesh: Mesh, color: Color) -> MeshInstance3D:
	var visual := MeshInstance3D.new()
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	visual.mesh = mesh
	visual.material_override = material
	add_child(visual)
	return visual


func fail(message: String) -> void:
	push_error(message)
	if status != null:
		status.text = message
	if smoke or "--rollback-replay" in OS.get_cmdline_user_args():
		get_tree().quit(1)
