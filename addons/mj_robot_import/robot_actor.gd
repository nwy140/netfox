@tool
extends Node3D

const RobotDefinition = preload("robot_definition.gd")
const RobotMotor = preload("res://robot_starter/robot_motor.gd")

@export var definition: RobotDefinition
@export var stable_id: StringName
@export var motor_controller: RobotMotor
