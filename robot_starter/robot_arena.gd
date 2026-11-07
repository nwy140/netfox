extends Node3D

const Actor := preload("res://addons/mj_robot_import/robot_actor.gd")
const Importer := preload("res://addons/mj_robot_import/robot_importer.gd")
const Simulation := preload("res://robot_starter/robot_simulation.gd")
const G1Motor := preload("res://robot_starter/g1_motor.gd")
const RoverMotor := preload("res://robot_starter/rover_motor.gd")
const JointMotor := preload("res://robot_starter/joint_test_motor.gd")
const PLAYER := 1
const AI := 0

@export var use_sample_roster := true

var simulation := Simulation.new()
var selected: StringName
var player_slot := -1
var elapsed := 0.0
var status: Label
var slots: Array[Actor]


func _ready() -> void:
	status = $HUD/Panel/Status
	if use_sample_roster and $Robots.get_child_count() == 0 and not make_sample():
		return
	for child in $Robots.get_children():
		if child is Actor:
			slots.append(child)
	for i in range(slots.size()):
		$HUD/Panel/Robot.add_item(String(slots[i].stable_id), i)
	var world := MjWorld.new()
	add_child(world)
	if not simulation.bind_model(world, slots):
		fail(simulation.error)
		return
	$HUD/Panel/Possess.pressed.connect(possess_selected)
	$HUD/Panel/Release.pressed.connect(func() -> void: player_slot = -1)
	$HUD/Panel/Robot.item_selected.connect(update_joint_panel)
	$HUD/Panel/Joint.item_selected.connect(configure_joint_test)
	if not slots.is_empty():
		update_joint_panel(0)
	simulation.refresh()
	if "--robot-arena-smoke" in OS.get_cmdline_user_args():
		replay_smoke.call_deferred()


func make_sample() -> bool:
	var importer := Importer.new()
	var g1 := importer.build_robot("res://models/g1_walk/g1_12dof.xml")
	if g1 == null:
		fail(importer.error)
		return false
	var rover := importer.build_robot("res://robot_starter/models/rover/rover.xml")
	if rover == null:
		fail(importer.error)
		return false
	spawn("g1", g1, G1Motor.new(), Vector3(-1.6, 0, -1.1), 0.0)
	spawn("rover_a", rover, RoverMotor.new(), Vector3(-1, 0, 1.1), 0.0)
	spawn("rover_b", rover, RoverMotor.new(), Vector3(1, 0, 1.1), PI)
	return true


func spawn(id: StringName, definition: Resource, motor: Resource, position: Vector3, yaw: float) -> void:
	var actor := Actor.new()
	actor.name = id
	actor.stable_id = id
	actor.definition = definition
	actor.motor_controller = motor
	actor.position = position
	actor.rotation.y = yaw
	actor.add_child(definition.visuals.instantiate())
	$Robots.add_child(actor)


func possess_selected() -> void:
	player_slot = $HUD/Panel/Robot.selected


func update_joint_panel(index: int) -> void:
	var joint: OptionButton = $HUD/Panel/Joint
	joint.clear()
	var actor := slots[index]
	joint.visible = actor.motor_controller == null
	if joint.visible:
		joint.add_item("Joint test: off")
		for actuator in actor.definition.actuators:
			joint.add_item(actuator)


func configure_joint_test(index: int) -> void:
	var actor := slots[$HUD/Panel/Robot.selected]
	if actor.motor_controller != null:
		return
	var id := actor.stable_id
	if simulation.motors.has(id):
		var current := simulation.motors[id] as JointMotor
		simulation.world.set_ctrl(current.actuator_id, 0.0)
		simulation.motors.erase(id)
	if index > 0:
		var motor := JointMotor.new()
		motor.actuator = $HUD/Panel/Joint.get_item_text(index)
		if motor.bind_model(actor.definition, simulation.bindings[String(id)]):
			simulation.motors[id] = motor
			player_slot = $HUD/Panel/Robot.selected


func _physics_process(delta: float) -> void:
	if simulation.world == null or not simulation.error.is_empty() 			or "--robot-arena-smoke" in OS.get_cmdline_user_args():
		return
	elapsed += delta
	while elapsed >= 1.0 / Simulation.TICKS_PER_SECOND:
		elapsed -= 1.0 / Simulation.TICKS_PER_SECOND
		run_tick(keyboard_intent())
	simulation.refresh()
	var role := String(slots[player_slot].stable_id) if player_slot >= 0 else "AI owns all robots"
	status.text = "%s  |  tick %d\nW/S forward/back  A/D turn" % [role, simulation.tick]


func keyboard_intent() -> Vector3:
	return Vector3(
		float(Input.is_physical_key_pressed(KEY_W)) - float(Input.is_physical_key_pressed(KEY_S)),
		0.0, float(Input.is_physical_key_pressed(KEY_A)) - float(Input.is_physical_key_pressed(KEY_D)))


func run_tick(intent: Vector3) -> void:
	var commands: Dictionary
	var handoffs: Dictionary
	for i in range(slots.size()):
		var id := slots[i].stable_id
		var owner := PLAYER if i == player_slot else AI
		var revision := simulation.revisions[id]
		if simulation.owners[id] != owner:
			handoffs[id] = owner
			revision += 1
		var desired := intent if owner == PLAYER else ai_intent(id, simulation.tick)
		commands[id] = {"tick": simulation.tick, "owner": owner, "revision": revision, "intent": desired}
	simulation.step(commands, handoffs)


func ai_intent(id: StringName, tick: int) -> Vector3:
	if simulation.motors.get(id) is JointMotor:
		return Vector3.ZERO
	if id == &"g1":
		return Vector3(0.35, 0.0, 0.15)
	return Vector3(0.45, 0.0, 0.25 if (tick / 90) % 2 == 0 else -0.25)


func replay_smoke() -> void:
	var pelvis := simulation.world.body_id("g1__pelvis")
	var initial := simulation.world.body_world_position(pelvis)
	for i in range(40):
		run_tick(Vector3.ZERO)
	var checkpoint := simulation.capture()
	for i in range(70):
		scripted_input(i)
	var expected := simulation.capture()
	var moved := simulation.world.body_world_position(pelvis).distance_to(initial)
	if not simulation.restore(checkpoint):
		fail("Articulated checkpoint could not be restored.")
		return
	player_slot = -1
	for i in range(70):
		scripted_input(i)
	var actual := simulation.capture()
	var error := 0.0
	for i in range(actual.physics.size()):
		error = maxf(error, absf(expected.physics[i] - actual.physics[i]))
	var policy_equal: bool = expected.motors[&"g1"] == actual.motors[&"g1"]
	var upright := simulation.world.body_world_position(pelvis).z > 0.42
	var roster_equal: bool = expected.owners == actual.owners and expected.revisions == actual.revisions
	var roster_valid: bool = actual.revisions[&"g1"] == 2 and actual.revisions[&"rover_b"] == 2
	var stable_clock: bool = actual.remainder == expected.remainder and actual.substep == expected.substep
	if error > 1e-9 or not policy_equal or not roster_equal or not roster_valid or not stable_clock or not upright or moved < 0.15:
		fail("Articulated replay: error=%s policy=%s ownership=%s clock=%s upright=%s moved=%f" % [
			error, policy_equal, roster_equal and roster_valid, stable_clock, upright, moved])
		return
	var rover := simulation.motors[&"rover_b"] as RoverMotor
	var stale := {"tick": simulation.tick, "owner": PLAYER, "revision": 1, "intent": Vector3.RIGHT}
	simulation.step({&"rover_b": stale})
	if simulation.world.get_ctrl(rover.left_id) != 0.0:
		fail("A command from the previous controller changed torque.")
		return
	print("ROBOT ARENA PASS error=%.12f policy_equal=%s moved=%.3fm checkpoint_bytes=%d" % [
		error, policy_equal, moved, var_to_bytes(actual).size()])
	get_tree().quit()


func scripted_input(i: int) -> void:
	if i == 0:
		player_slot = 0
	if i == 25:
		player_slot = 2
	if i == 50:
		player_slot = -1
	run_tick(Vector3(0.3, 0.0, 0.1))


func fail(message: String) -> void:
	status.text = message
	push_error(message)
	if "--robot-arena-smoke" in OS.get_cmdline_user_args():
		get_tree().quit(1)
