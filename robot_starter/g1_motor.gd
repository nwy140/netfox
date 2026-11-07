extends "res://robot_starter/robot_motor.gd"

const Policy := preload("res://scripts/g1_locomotion_policy.gd")
const Walk := preload("res://scripts/unitree_g1_walk.gd")
const JOINTS := ["left_hip_pitch_joint", "left_hip_roll_joint", "left_hip_yaw_joint",
	"left_knee_joint", "left_ankle_pitch_joint", "left_ankle_roll_joint", "right_hip_pitch_joint",
	"right_hip_roll_joint", "right_hip_yaw_joint", "right_knee_joint", "right_ankle_pitch_joint",
	"right_ankle_roll_joint"]

@export_file("*.bin") var weights := "res://models/g1_walk/policy.bin"

var policy := Policy.new()
var actuator_ids: PackedInt32Array
var position_offset := 0
var velocity_offset := 0
var action := PackedFloat32Array()
var targets := PackedFloat64Array(Walk.DEFAULT)
var fallen := false


func bind_model(definition: Resource, binding: Dictionary) -> bool:
	if definition.position_count != 19 or definition.velocity_count != 18 			or definition.joints.size() != 13 or definition.actuators.size() != 12 			or definition.root_body != "pelvis" or definition.joints[0] != "floating_base_joint":
		return false
	position_offset = binding.position_offset
	velocity_offset = binding.velocity_offset
	for i in range(JOINTS.size()):
		var joint_name: String = JOINTS[i]
		if definition.joints[i + 1] != joint_name or not binding.actuators.has(joint_name):
			return false
		actuator_ids.append(binding.actuators[joint_name])
	action.resize(12)
	return policy.load_weights(weights)


func apply(world: MjWorld, q: PackedFloat64Array, v: PackedFloat64Array,
		command: Vector3, substep: int) -> void:
	var p := position_offset
	var d := velocity_offset
	if substep > 0 and substep % Walk.DECIMATION == 0:
		fallen = q[p + 2] < 0.42
		if not fallen:
			var rotation := Quaternion(q[p + 4], q[p + 5], q[p + 6], q[p + 3]).normalized()
			var gravity := rotation.inverse() * Vector3(0, 0, -1)
			var phase := TAU * fmod(world.get_time(), 0.8) / 0.8
			var obs := PackedFloat32Array([
				v[d + 3] * 0.25, v[d + 4] * 0.25, v[d + 5] * 0.25,
				gravity.x, gravity.y, gravity.z, command.x * 2.0, command.y * 2.0, command.z * 0.25])
			obs.resize(47)
			for i in range(12):
				obs[9 + i] = q[p + 7 + i] - Walk.DEFAULT[i]
				obs[21 + i] = v[d + 6 + i] * 0.05
				obs[33 + i] = action[i]
			obs[45] = sin(phase)
			obs[46] = cos(phase)
			action = policy.evaluate(obs)
			for i in range(12):
				targets[i] = Walk.DEFAULT[i] + 0.25 * action[i]
	for i in range(12):
		var torque: float = (targets[i] - q[p + 7 + i]) * Walk.KP[i] - v[d + 6 + i] * Walk.KD[i]
		world.set_ctrl(actuator_ids[i], 0.0 if fallen else torque)


func capture() -> Dictionary:
	return {"hidden": policy.hidden.duplicate(), "cell": policy.cell.duplicate(),
		"action": action.duplicate(), "targets": targets.duplicate(), "fallen": fallen}


func restore(state: Dictionary) -> void:
	policy.hidden = state.hidden.duplicate()
	policy.cell = state.cell.duplicate()
	action = state.action.duplicate()
	targets = state.targets.duplicate()
	fallen = state.fallen
