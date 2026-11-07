extends "res://robot_starter/robot_motor.gd"

@export var left_actuator := "left_drive"
@export var right_actuator := "right_drive"
@export_range(0.0, 1.0) var torque := 0.6

var left_id := -1
var right_id := -1


func bind_model(_definition: Resource, binding: Dictionary) -> bool:
	left_id = binding.actuators.get(left_actuator, -1)
	right_id = binding.actuators.get(right_actuator, -1)
	return left_id >= 0 and right_id >= 0 and left_id != right_id


func apply(world: MjWorld, _positions: PackedFloat64Array, _velocities: PackedFloat64Array,
		command: Vector3, _substep: int) -> void:
	world.set_ctrl(left_id, clampf(command.x - command.z, -1, 1) * torque)
	world.set_ctrl(right_id, clampf(command.x + command.z, -1, 1) * torque)
