@tool
extends "res://scripts/unitree_g1.gd"

const Policy = preload("res://scripts/g1_locomotion_policy.gd")
const DT := 0.002
const DECIMATION := 10
const DEFAULT := [-0.1, 0.0, 0.0, 0.3, -0.2, 0.0, -0.1, 0.0, 0.0, 0.3, -0.2, 0.0]
const KP := [100.0, 100.0, 100.0, 150.0, 40.0, 40.0, 100.0, 100.0, 100.0, 150.0, 40.0, 40.0]
const KD := [2.0, 2.0, 2.0, 4.0, 2.0, 2.0, 2.0, 2.0, 2.0, 4.0, 2.0, 2.0]
const WAYPOINTS := [Vector2(2, 0), Vector2(2, 2), Vector2(0, 2), Vector2.ZERO]

var policy := Policy.new()
var action := PackedFloat32Array()
var targets := PackedFloat64Array()
var torques := PackedFloat64Array()
var ticks := 0
var waypoint := 0
var waypoints_reached := 0
var wait_until := 0.0
var patrol := true
var face_camera := false
var fallen := false
var command := Vector3.ZERO
var external_drive := false
var external_intent := Vector3.ZERO


func _ready() -> void:
	if not Engine.is_editor_hint():
		if not policy.load_weights(model_dir + "policy.bin"):
			fail("Missing or invalid G1 walking policy")
			return
		if "--g1-policy-check" in OS.get_cmdline_user_args():
			var sample := PackedFloat32Array()
			sample.resize(47)
			for i in range(47):
				sample[i] = sin(float(i)) * 0.3
			for i in range(3):
				print("POLICY ", JSON.stringify(Array(policy.evaluate(sample))))
			get_tree().quit()
			return
	super._ready()
	if Engine.is_editor_hint() or world == null or not world.is_ready():
		return
	if "--g1-walk-smoke" in OS.get_cmdline_user_args():
		walk_smoke()
	if "--g1-checkpoint-smoke" in OS.get_cmdline_user_args():
		checkpoint_smoke()


func fail(message: String) -> void:
	super.fail(message)
	if "--g1-walk-smoke" in OS.get_cmdline_user_args() or "--g1-policy-check" in OS.get_cmdline_user_args():
		get_tree().quit(1)


func reset() -> void:
	if world.get_nq() != 19 or world.get_nv() != 18 or world.get_nu() != 12:
		fail("The walking policy requires the Unitree 12-actuator model")
		world.free_model()
		return
	world.reset()
	world.set_timestep(DT)
	policy.reset()
	action.resize(12)
	action.fill(0.0)
	targets = PackedFloat64Array(DEFAULT)
	torques.resize(12)
	ticks = 0
	step_budget = 0.0
	wait_until = 0.0
	waypoint = 0
	waypoints_reached = 0
	fallen = false
	command = Vector3.ZERO
	refresh()


func _physics_process(delta: float) -> void:
	advance_simulation(delta)


func advance_simulation(delta: float) -> void:
	if Engine.is_editor_hint() or world == null or not world.is_ready() or paused or fallen:
		return
	step_budget += delta
	while step_budget >= DT:
		step_budget -= DT
		simulate_step()
		if fallen:
			break
	refresh()


func simulate_step() -> void:
	var q := world.get_qpos()
	var velocity := world.get_qvel()
	for i in range(12):
		torques[i] = (targets[i] - q[i + 7]) * KP[i] - velocity[i + 6] * KD[i]
	world.set_ctrl_array(torques)
	world.step(1)
	ticks += 1
	if ticks % DECIMATION == 0:
		var pose := world.get_qpos()
		fallen = pose[2] < 0.42
		if not fallen:
			update_targets(pose, world.get_qvel())


func update_targets(q: PackedFloat64Array, velocity: PackedFloat64Array) -> void:
	var rotation := Quaternion(q[4], q[5], q[6], q[3]).normalized()
	var gravity := rotation.inverse() * Vector3(0, 0, -1)
	command = desired_velocity(Vector2(q[0], q[1]), rotation)
	var phase := TAU * fmod(world.get_time(), 0.8) / 0.8
	var obs := PackedFloat32Array([
		velocity[3] * 0.25, velocity[4] * 0.25, velocity[5] * 0.25,
		gravity.x, gravity.y, gravity.z, command.x * 2.0, command.y * 2.0, command.z * 0.25])
	obs.resize(47)
	for i in range(12):
		obs[9 + i] = q[7 + i] - DEFAULT[i]
		obs[21 + i] = velocity[6 + i] * 0.05
		obs[33 + i] = action[i]
	obs[45] = sin(phase)
	obs[46] = cos(phase)
	action = policy.evaluate(obs)
	for i in range(12):
		targets[i] = DEFAULT[i] + 0.25 * action[i]


func desired_velocity(position: Vector2, rotation: Quaternion) -> Vector3:
	var manual := drive_intent()
	if manual != Vector3.ZERO:
		return manual
	var facing := rotation * Vector3.RIGHT
	if face_camera:
		# The follow camera is offset in Godot +X/+Z, or MuJoCo +X/-Y.
		var camera_heading := Vector2(facing.x, facing.y).angle_to(Vector2(2.5, -2.3))
		return Vector3(0.0, 0.0, clampf(camera_heading * 1.6, -0.8, 0.8))
	if not patrol or world.get_time() < wait_until:
		return Vector3.ZERO
	var offset: Vector2 = WAYPOINTS[waypoint] - position
	if offset.length() < 0.35:
		waypoint = (waypoint + 1) % WAYPOINTS.size()
		waypoints_reached += 1
		wait_until = world.get_time() + 1.5
		return Vector3.ZERO
	var heading := Vector2(facing.x, facing.y).angle_to(offset)
	return Vector3(clampf(offset.length() * 0.7, 0.2, 0.5) * maxf(0.0, cos(heading)),
		0.0, clampf(heading * 1.6, -0.8, 0.8))


func drive_intent() -> Vector3:
	if external_drive:
		return external_intent
	return keyboard_intent()


func keyboard_intent() -> Vector3:
	var forward := (
		float(Input.is_physical_key_pressed(KEY_W)) - float(Input.is_physical_key_pressed(KEY_S)))
	var turn := float(Input.is_physical_key_pressed(KEY_A)) - float(Input.is_physical_key_pressed(KEY_D))
	return Vector3(forward * 0.5, 0.0, turn * 0.7)


func _unhandled_key_input(event: InputEvent) -> void:
	if Engine.is_editor_hint() or world == null or not world.is_ready():
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_P:
				patrol = not patrol
				face_camera = false
			KEY_E:
				face_camera = not face_camera
			KEY_SPACE:
				paused = not paused
			KEY_R:
				reset()
		refresh()


func refresh() -> void:
	super.refresh()
	var pelvis: Node3D = links[world.body_id("pelvis")]
	var camera := $Camera3D as Camera3D
	var center := Vector3(pelvis.global_position.x, 0.65, pelvis.global_position.z)
	camera.look_at_from_position(center + Vector3(2.5, 1.35, 2.3), center)
	var marker := $Waypoint as MeshInstance3D
	var destination: Vector2 = WAYPOINTS[waypoint]
	marker.position = Vector3(destination.x, 0.007, -destination.y)
	marker.visible = patrol and not face_camera
	var mode := "Patrol" if patrol else "Manual"
	if face_camera:
		mode = "Facing camera"
	if fallen:
		mode = "Fallen · R to reset"
	elif paused:
		mode = "Paused"
	status.text = " UNITREE G1  |  WALK LAB \n %s   %.1f s   %.2f m/s   %.2f rad/s \n WASD: drive   P: patrol   E: face camera   Space: pause   R: reset " % [
		mode, world.get_time(), command.x, command.z]


func walk_smoke() -> void:
	for i in range(12500):
		simulate_step()
		if fallen:
			break
	var q := world.get_qpos()
	if fallen or waypoints_reached < 4 or q[2] < 0.55:
		fail("G1 WALK FAIL: t=%.2f, reached=%d, pelvis=%.2f" % [
			world.get_time(), waypoints_reached, q[2]])
		return
	var reached := waypoints_reached
	reset()
	face_camera = true
	for i in range(2000):
		simulate_step()
		if fallen:
			break
	q = world.get_qpos()
	var facing := Quaternion(q[4], q[5], q[6], q[3]) * Vector3.RIGHT
	var error := absf(Vector2(facing.x, facing.y).angle_to(Vector2(2.5, -2.3)))
	if fallen or error > 0.35:
		fail("G1 WALK FAIL: camera-facing error %.2f rad" % error)
		return
	face_camera = false
	patrol = false
	var idle_position := Vector2(q[0], q[1])
	for i in range(1000):
		simulate_step()
		if fallen:
			break
	q = world.get_qpos()
	var drift := idle_position.distance_to(Vector2(q[0], q[1]))
	if fallen or drift > 0.5:
		fail("G1 WALK FAIL: idle drift %.2f m" % drift)
		return
	print("G1 WALK PASS: %d waypoints, camera-facing error %.2f rad, idle drift %.2f m" % [
		reached, error, drift])
	get_tree().quit()

# Physics and policy must be captured on the same simulation tick.
func capture_checkpoint() -> Dictionary:
	return {
		"version": 1, "model": checkpoint_model(), "state": world.capture_state(),
		"ticks": ticks, "budget": step_budget, "waypoint": waypoint,
		"reached": waypoints_reached, "wait": wait_until, "patrol": patrol,
		"face": face_camera, "fallen": fallen, "paused": paused, "command": command,
		"hidden": policy.hidden.duplicate(), "cell": policy.cell.duplicate(),
		"action": action.duplicate(), "targets": targets.duplicate(),
	}


func checkpoint_model() -> String:
	return "unitree-rl-gym-276801e-g1-12dof-50hz:" + world.get_mujoco_version()


func restore_checkpoint(data: Dictionary) -> bool:
	if data.get("version") != 1 or data.get("model") != checkpoint_model():
		return false
	for key in ["ticks", "waypoint", "reached"]:
		if typeof(data.get(key)) != TYPE_INT or data[key] < 0:
			return false
	if data.waypoint >= WAYPOINTS.size():
		return false
	for key in ["budget", "wait"]:
		if typeof(data.get(key)) != TYPE_FLOAT or not is_finite(data[key]) or data[key] < 0.0:
			return false
	if data.budget > 1.0:
		return false
	for key in ["patrol", "face", "fallen", "paused"]:
		if typeof(data.get(key)) != TYPE_BOOL:
			return false
	if typeof(data.get("command")) != TYPE_VECTOR3 or not data.command.is_finite():
		return false
	for key in ["hidden", "cell", "action"]:
		if typeof(data.get(key)) != TYPE_PACKED_FLOAT32_ARRAY:
			return false
		if data[key].size() != (12 if key == "action" else 64):
			return false
		for value in data[key]:
			if not is_finite(value):
				return false
	if typeof(data.get("targets")) != TYPE_PACKED_FLOAT64_ARRAY or data.targets.size() != 12:
		return false
	for value in data.targets:
		if not is_finite(value):
			return false
	if typeof(data.get("state")) != TYPE_PACKED_FLOAT64_ARRAY or not world.restore_state(data.state):
		return false
	ticks = data.ticks
	step_budget = data.budget
	waypoint = data.waypoint
	waypoints_reached = data.reached
	wait_until = data.wait
	patrol = data.patrol
	face_camera = data.face
	fallen = data.fallen
	paused = data.paused
	command = data.command
	policy.hidden = data.hidden.duplicate()
	policy.cell = data.cell.duplicate()
	action = data.action.duplicate()
	targets = data.targets.duplicate()
	return true


func checkpoint_smoke() -> void:
	for i in range(1357):
		simulate_step()
	var checkpoint := capture_checkpoint()
	for i in range(650):
		simulate_step()
	var expected := capture_checkpoint()
	var invalid := checkpoint.duplicate()
	invalid.targets = PackedFloat64Array([NAN])
	if restore_checkpoint(invalid) or world.capture_state() != expected.state or not restore_checkpoint(checkpoint):
		push_error("G1 CHECKPOINT FAIL: checkpoint validation or restore")
		get_tree().quit(1)
		return
	for i in range(650):
		simulate_step()
	var actual := capture_checkpoint()
	var error := 0.0
	for i in range(actual.state.size()):
		error = maxf(error, absf(actual.state[i] - expected.state[i]))
	if error > 1e-8 or actual.ticks != expected.ticks or actual.hidden != expected.hidden or actual.cell != expected.cell:
		push_error("G1 CHECKPOINT FAIL: continuation error %s" % error)
		get_tree().quit(1)
		return
	print("G1 CHECKPOINT PASS: 650 resumed steps, maximum integration-state error %s" % error)
	get_tree().quit()
