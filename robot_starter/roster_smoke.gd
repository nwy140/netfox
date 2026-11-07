extends SceneTree

const Definition = preload("res://addons/mj_robot_import/robot_definition.gd")
const Roster = preload("res://robot_starter/robot_roster.gd")


func _initialize() -> void:
	run.call_deferred()


func run() -> void:
	var g1 := load("user://robot_import_smoke_v2/g1_12dof/robot.tres") as Definition
	var rover := load("user://robot_import_smoke_v2/rover/robot.tres") as Definition
	if g1 == null or rover == null:
		push_error("Run import_smoke.gd first.")
		quit(1)
		return
	var world := MjWorld.new()
	var roster := Roster.new()
	var robots: Array[Dictionary] = [
		{"id": "grey", "position": Vector3(0, 0, -2), "definition": g1},
		{"id": "first", "position": Vector3(-1, 0, 0), "definition": rover},
		{"id": "second", "position": Vector3(1, 0, 0), "yaw": PI, "definition": rover},
	]
	if not roster.compile(world, robots):
		push_error(roster.error)
		world.free()
		quit(1)
		return
	var left := world.body_id("first__chassis")
	var right := world.body_id("second__chassis")
	var start := world.body_world_position(left)
	var contact := false
	for i in range(1300):
		for prefix in ["first__", "second__"]:
			for wheel in ["left_drive", "right_drive"]:
				world.set_ctrl(world.actuator_id(prefix + wheel), 0.4)
		world.step()
		for pair in world.get_contacts():
			if Vector2(pair.pos.x, pair.pos.y).length() < 0.25 and pair.pos.z > 0.05:
				contact = true
	world.forward()
	var movement := world.body_world_position(left).distance_to(start)
	print("ROBOT ROSTER bodies=%d actuators=%d motion=%f contact=%s" % [world.get_nbody(), world.get_nu(), movement, contact])
	var ok := left > 0 and right > 0 and left != right and world.get_nu() == 16 and movement > 0.3 and contact
	world.free()
	quit(0 if ok else 1)
