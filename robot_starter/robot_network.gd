extends Node

const PORT := 29477
const HISTORY := 60
const HOST := 1
const CLIENT := 2
const AI := 0
const VERSION := 1

var arena: Node3D
var active := false
var hosting := false
var remote_peer := 0
var smoke := false
var impaired := false
var host_slot := -1
var client_slot := -1
var host_intent := Vector3.ZERO
var client_intent := Vector3.ZERO
var client_inputs: Dictionary[int, Dictionary]
var local_inputs: Dictionary[int, Dictionary]
var predictions: Dictionary[int, PackedFloat64Array]
var pending: Dictionary
var confirmed := -1
var acknowledged := -1
var latest := -1
var replay_from := -1
var first_snapshot := -1
var injected_at := -1
var replay_count := 0
var peak_error := 0.0
var matching_error := INF
var peak_correction := 0.0
var peak_replay_us := 0
var replay_start_us := 0
var before_replay := Vector3.ZERO
var snapshot_size := 0
var remote_frames: Array[Dictionary]
var render_tick := -1.0


func configure(parent: Node3D) -> void:
	arena = parent
	var args := OS.get_cmdline_user_args()
	smoke = "--robot-net-host" in args or "--robot-net-client" in args
	impaired = "--rollback-impaired" in args
	NetworkTime.on_tick.connect(on_tick)
	NetworkRollback.before_loop.connect(begin_replay)
	NetworkRollback.on_process_tick.connect(replay)
	NetworkRollback.after_loop.connect(end_replay)
	multiplayer.connected_to_server.connect(announce)
	multiplayer.connection_failed.connect(func() -> void: arena.fail("LAN connection failed. Reopen the arena."))
	multiplayer.server_disconnected.connect(func() -> void: arena.fail("LAN host disconnected. Reopen the arena."))
	if smoke:
		open("--robot-net-host" in args, "127.0.0.1")


func open(as_host: bool, address: String) -> void:
	if active:
		return
	var peer := ENetMultiplayerPeer.new()
	var result := peer.create_server(PORT, 1) if as_host else peer.create_client(address, PORT)
	if result != OK:
		arena.fail(error_string(result))
		return
	active = true
	hosting = as_host
	host_slot = 0 if not arena.slots.is_empty() else -1
	client_slot = arena.slots.size() - 1 if arena.slots.size() > 1 else -1
	get_tree().set_meta("g1_lan", true)
	multiplayer.multiplayer_peer = peer
	arena.status.text = "Waiting for LAN peer" if hosting else "Connecting to LAN host"
	if hosting:
		print("ROBOT NET HOST READY")


func announce() -> void:
	hello.rpc_id(1, VERSION, arena.simulation.signature)


@rpc("any_peer", "call_remote", "reliable")
func hello(version: int, signature: String) -> void:
	if not hosting or remote_peer != 0:
		return
	var sender := multiplayer.get_remote_sender_id()
	if version != VERSION or signature != arena.simulation.signature:
		incompatible.rpc_id(sender)
		return
	remote_peer = sender


@rpc("authority", "call_remote", "reliable")
func incompatible() -> void:
	arena.fail("The host is using a different robot roster or build.")


func request_slot(slot: int) -> void:
	if hosting and slot != client_slot:
		host_slot = slot
	elif not hosting and confirmed >= 0:
		choose_slot.rpc_id(1, slot)


@rpc("any_peer", "call_remote", "reliable")
func choose_slot(slot: int) -> void:
	if hosting and multiplayer.get_remote_sender_id() == remote_peer and slot != host_slot 			and slot >= -1 and slot < arena.slots.size():
		client_slot = slot


func on_tick(_delta: float, tick: int) -> void:
	if not active or not arena.simulation.error.is_empty():
		return
	if hosting:
		if remote_peer == 0 or not multiplayer.get_peers().has(remote_peer):
			return
		tick -= 3
		for input_tick in client_inputs.keys():
			if input_tick <= tick:
				if input_tick > acknowledged:
					acknowledged = input_tick
					var input: Dictionary = client_inputs[input_tick]
					var slot_id: StringName = arena.slots[client_slot].stable_id if client_slot >= 0 else &""
					if input.slot == slot_id and input.revision == arena.simulation.revisions.get(slot_id):
						client_intent = input.intent
					else:
						client_intent = Vector3.ZERO
				client_inputs.erase(input_tick)
		if tick - acknowledged > 9:
			client_intent = Vector3.ZERO
		host_intent = Vector3(0.35, 0.0, 0.15) if smoke else arena.keyboard_intent()
		if smoke and arena.simulation.tick == 80:
			client_slot = -1
			client_intent = Vector3.ZERO
		elif smoke and arena.simulation.tick == 110:
			client_slot = arena.slots.size() - 1
		step_match(host_intent, client_intent, true)
		if tick % 2 == 0:
			send_snapshot(tick)
		return
	if confirmed < 0 or not NetworkTime.is_initial_sync_done():
		return
	var intent: Vector3 = Vector3(0.55, 0.0, 0.08) if smoke else arena.keyboard_intent()
	var input := make_input(intent)
	local_inputs[tick] = input
	local_inputs.erase(tick - HISTORY)
	predictions.erase(tick - HISTORY)
	send_input(tick, input)
	latest = tick
	if smoke and injected_at < 0 and tick > first_snapshot + 45:
		intent = -intent
		injected_at = tick
	step_match(host_intent, intent, false)
	predictions[tick] = arena.simulation.world.capture_state()


func make_input(intent: Vector3) -> Dictionary:
	var owners: Dictionary = arena.simulation.owners
	for id in owners:
		if owners[id] == CLIENT:
			return {"slot": id, "revision": arena.simulation.revisions[id], "intent": intent}
	return {"slot": &"", "revision": -1, "intent": Vector3.ZERO}


func step_match(grey: Vector3, gold: Vector3, authoritative: bool) -> void:
	var commands: Dictionary
	var handoffs: Dictionary
	var sim = arena.simulation
	for i in range(arena.slots.size()):
		var id: StringName = arena.slots[i].stable_id
		var owner: int = sim.owners[id]
		var revision: int = sim.revisions[id]
		if authoritative:
			var new_owner := HOST if i == host_slot else (CLIENT if i == client_slot else AI)
			if new_owner != owner:
				handoffs[id] = new_owner
				owner = new_owner
				revision += 1
		var intent: Vector3 = arena.ai_intent(id, sim.tick)
		if owner == HOST:
			intent = grey
		elif owner == CLIENT:
			intent = gold
		commands[id] = {"tick": sim.tick, "owner": owner, "revision": revision, "intent": intent}
	sim.step(commands, handoffs)


func send_input(tick: int, input: Dictionary) -> void:
	if impaired:
		if tick % 5 == 0:
			return
		await get_tree().create_timer(0.08 + (tick % 7) * 0.005).timeout
	if multiplayer.has_multiplayer_peer():
		submit.rpc_id(1, tick, input.slot, input.revision, input.intent)


@rpc("any_peer", "call_remote", "unreliable")
func submit(tick: int, slot: StringName, revision: int, intent: Vector3) -> void:
	if hosting and multiplayer.get_remote_sender_id() == remote_peer and tick > acknowledged 			and absi(tick - NetworkTime.tick) < HISTORY and intent.is_finite() 			and intent.length_squared() <= 1.001 and String(slot).length() <= 64:
		client_inputs[tick] = {"slot": slot, "revision": revision, "intent": intent}


func send_snapshot(tick: int) -> void:
	var bytes := var_to_bytes(arena.simulation.capture())
	var input := host_intent
	var ack := acknowledged
	if impaired:
		if tick % 10 == 0:
			return
		await get_tree().create_timer(0.08 + (tick % 7) * 0.005).timeout
	if multiplayer.has_multiplayer_peer() and multiplayer.get_peers().has(remote_peer):
		snapshot.rpc_id(remote_peer, tick, ack, input, bytes)


@rpc("authority", "call_remote", "unreliable")
func snapshot(tick: int, ack: int, input: Vector3, bytes: PackedByteArray) -> void:
	if hosting or tick <= confirmed or tick <= pending.get("tick", -1) 			or absi(tick - NetworkTime.tick) >= HISTORY or not input.is_finite() 			or bytes.size() > 32768:
		return
	var state = bytes_to_var(bytes)
	if not arena.simulation.accepts_checkpoint(state):
		arena.fail("Host checkpoint was incompatible.")
		return
	pending = {"tick": tick, "ack": ack, "input": input, "state": state}
	snapshot_size = bytes.size()


func begin_replay() -> void:
	if hosting or pending.is_empty() or pending.tick >= NetworkTime.tick:
		return
	if first_snapshot < 0:
		first_snapshot = pending.tick
		latest = NetworkTime.tick - 1
	if latest < pending.tick:
		return
	if latest - pending.tick >= mini(HISTORY, NetworkRollback.history_limit):
		arena.fail("Checkpoint is older than the replay window.")
		pending.clear()
		return
	before_replay = local_position()
	if predictions.has(pending.tick):
		matching_error = compare_state(predictions[pending.tick], pending.state.physics)
		peak_error = maxf(peak_error, matching_error)
	if not arena.simulation.restore(pending.state):
		arena.fail("Host checkpoint could not be restored.")
		return
	confirmed = pending.tick
	acknowledged = pending.ack
	host_intent = pending.input
	remote_frames.append({"tick": confirmed, "poses": arena.simulation.poses()})
	if remote_frames.size() > 24:
		remote_frames.pop_front()
	pending.clear()
	replay_from = confirmed + 1
	replay_start_us = Time.get_ticks_usec()
	NetworkRollback.notify_resimulation_start(replay_from)


func replay(tick: int) -> void:
	if replay_from < 0 or tick < replay_from or tick > latest:
		return
	var input: Dictionary = local_inputs.get(tick, {})
	var current := make_input(Vector3.ZERO)
	var intent := Vector3.ZERO
	if input.get("slot") == current.slot and input.get("revision") == current.revision:
		intent = input.intent
	step_match(host_intent, intent, false)
	predictions[tick] = arena.simulation.world.capture_state()
	replay_count += 1


func end_replay() -> void:
	if replay_from < 0:
		return
	peak_replay_us = maxi(peak_replay_us, Time.get_ticks_usec() - replay_start_us)
	peak_correction = maxf(peak_correction, before_replay.distance_to(local_position()))
	replay_from = -1
	if not smoke or confirmed < first_snapshot + 170:
		return
	var sim = arena.simulation
	var g1: StringName = arena.slots[0].stable_id
	var rover: StringName = arena.slots.back().stable_id
	var g1_position: Vector3 = sim.world.body_world_position(sim.bindings[String(g1)].bodies.pelvis)
	if replay_count <= 0 or matching_error > 1e-7 or sim.revisions[rover] < 3 			or g1_position.z < 0.42 or absf(g1_position.x + 1.6) < 0.25 or injected_at < 0:
		arena.fail("Robot network smoke failed: error=%s revisions=%s upright=%s" % [
			matching_error, sim.revisions, g1_position.z])
		return
	print("ROBOT NET PASS tick=%d ack=%d replayed=%d peak_error=%.9f final_error=%.9f correction_m=%.6f replay_us=%d snapshot_bytes=%d" % [
		confirmed, acknowledged, replay_count, peak_error, matching_error, peak_correction, peak_replay_us, snapshot_size])
	get_tree().quit()


func local_position() -> Vector3:
	var sim = arena.simulation
	var slot := make_input(Vector3.ZERO).slot as StringName
	if slot.is_empty():
		return Vector3.ZERO
	for actor in arena.slots:
		if actor.stable_id == slot:
			return sim.world.body_world_position(sim.bindings[String(slot)].bodies[actor.definition.root_body])
	return Vector3.ZERO


func present(delta: float) -> void:
	if hosting or remote_frames.is_empty():
		arena.simulation.refresh()
		return
	var latest_remote: float = remote_frames.back().tick
	if render_tick < 0.0 or latest_remote - render_tick > 7.0:
		render_tick = latest_remote - 3.0
	render_tick = minf(render_tick + delta * 30.0, latest_remote)
	while remote_frames.size() > 2 and remote_frames[1].tick <= render_tick:
		remote_frames.pop_front()
	var a := remote_frames[0]
	var b := remote_frames[mini(1, remote_frames.size() - 1)]
	var weight := clampf((render_tick - a.tick) / maxf(1.0, b.tick - a.tick), 0.0, 1.0)
	arena.simulation.refresh_interpolated(a.poses, b.poses, weight, CLIENT)


func compare_state(a: PackedFloat64Array, b: PackedFloat64Array) -> float:
	var error := 0.0
	for i in range(a.size()):
		error = maxf(error, absf(a[i] - b[i]))
	return error
