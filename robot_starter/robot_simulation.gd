extends RefCounted

const Actor := preload("res://addons/mj_robot_import/robot_actor.gd")
const Motor := preload("res://robot_starter/robot_motor.gd")
const Roster := preload("res://robot_starter/robot_roster.gd")
const TICKS_PER_SECOND := 30
const SUBSTEPS_PER_SECOND := 500

var world: MjWorld
var actors: Array[Actor]
var motors: Dictionary[StringName, Motor]
var bindings: Dictionary
var owners: Dictionary[StringName, int]
var revisions: Dictionary[StringName, int]
var tick := 0
var substep := 0
var remainder := 0
var error: String


func bind_model(simulation: MjWorld, roster: Array[Actor]) -> bool:
	world = simulation
	actors = roster
	var entries: Array[Dictionary]
	for actor in actors:
		entries.append({"id": String(actor.stable_id), "position": actor.global_position,
			"yaw": actor.global_rotation.y, "definition": actor.definition})
	var compiler := Roster.new()
	if not compiler.compile(world, entries):
		error = compiler.error
		return false
	bindings = compiler.bindings
	for actor in actors:
		var id := actor.stable_id
		owners[id] = 0
		revisions[id] = 0
		if actor.motor_controller != null:
			var motor := actor.motor_controller.duplicate() as Motor
			if motor == null or not motor.bind_model(actor.definition, bindings[String(id)]):
				error = "Incompatible motor on " + String(id)
				return false
			motors[id] = motor
	return true


func step(commands: Dictionary, handoffs: Dictionary = {}) -> void:
	for id in handoffs:
		if owners.has(id) and owners[id] != handoffs[id]:
			owners[id] = handoffs[id]
			revisions[id] += 1
	remainder += SUBSTEPS_PER_SECOND
	var count := int(remainder / float(TICKS_PER_SECOND))
	remainder %= TICKS_PER_SECOND
	for i in range(count):
		var positions := world.get_qpos()
		var velocities := world.get_qvel()
		for id in motors:
			var input: Dictionary = commands.get(id, {})
			var command := Vector3.ZERO
			if input.get("tick") == tick and input.get("owner") == owners[id] 					and input.get("revision") == revisions[id]:
				var value: Vector3 = input.get("intent", Vector3.ZERO)
				if value.is_finite():
					command = value.limit_length()
			motors[id].apply(world, positions, velocities, command, substep)
		world.step()
		substep += 1
	world.forward()
	tick += 1


func capture() -> Dictionary:
	var motor_states: Dictionary
	for id in motors:
		motor_states[id] = motors[id].capture()
	return {"physics": world.capture_state(), "tick": tick, "substep": substep,
		"remainder": remainder, "owners": owners.duplicate(), "revisions": revisions.duplicate(),
		"motors": motor_states}


# Internal, trusted checkpoint. Validate a wire representation before calling this.
func restore(state: Dictionary) -> bool:
	if not world.restore_state(state.physics):
		return false
	tick = state.tick
	substep = state.substep
	remainder = state.remainder
	owners = state.owners.duplicate()
	revisions = state.revisions.duplicate()
	for id in motors:
		motors[id].restore(state.motors[id])
	return true


func refresh() -> void:
	for actor in actors:
		var ids: Dictionary = bindings[String(actor.stable_id)].bodies
		for link in actor.get_node("Visuals").get_children():
			var id: int = ids[link.get_meta("mj_body")]
			link.global_transform = preload("res://addons/mj_robot_import/robot_importer.gd").FRAME * world.body_world_transform(id)
