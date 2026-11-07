extends "res://robot_starter/robot_motor.gd"

# A conservative direct-actuator test for models without a locomotion policy.
@export var actuator: String
@export_range(0.0, 1.0) var maximum_command := 0.1

var actuator_id := -1


func bind_model(_definition: Resource, binding: Dictionary) -> bool:
	actuator_id = binding.actuators.get(actuator, -1)
	return actuator_id >= 0


func apply(world: MjWorld, _positions: PackedFloat64Array, _velocities: PackedFloat64Array,
		command: Vector3, _substep: int) -> void:
	world.set_ctrl(actuator_id, clampf(command.x, -1, 1) * maximum_command)
