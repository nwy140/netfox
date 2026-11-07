@tool
extends Node3D

const MODEL_DIR := "res://models/mujoco_menagerie/unitree_g1/"
@export var model_dir := MODEL_DIR
@export var mesh_dir := "assets/"

var world: MjWorld
var links: Dictionary[int, Node3D]
var paused := false
var step_budget := 0.0

@onready var status: Label = $UI/Panel/Status


func _ready() -> void:
	var model_path := model_dir + "scene.xml"
	var has_assets := FileAccess.file_exists(model_path)
	if has_assets:
		for child in $Robot.find_children("*", "MeshInstance3D"):
			var visual := child as MeshInstance3D
			visual.mesh = load_stl(model_dir + mesh_dir + str(visual.get_meta("stl")))
			var material := StandardMaterial3D.new()
			material.albedo_color = Color("#26313d") if visual.get_meta("dark") else Color("#a6bdcb")
			material.roughness = 0.43
			visual.material_override = material
	if Engine.is_editor_hint():
		return
	if not has_assets:
		fail("Missing Unitree G1 model under " + model_dir)
		return
	world = MjWorld.new()
	add_child(world)
	if not world.load_model(model_path):
		fail(world.get_last_error())
		return
	for child in $Robot.find_children("*", "Node3D"):
		if child is MeshInstance3D:
			if child.mesh == null:
				fail("Could not load visual mesh " + str(child.get_meta("stl")))
				world.free_model()
				return
			continue
		var id := world.body_id(child.name)
		if id < 0:
			fail("Missing robot link " + str(child.name))
			world.free_model()
			return
		links[id] = child
	reset()
	if "--g1-smoke" in OS.get_cmdline_user_args():
		smoke_test()


func load_stl(path: String) -> ArrayMesh:
	# Menagerie supplies binary STL meshes in each link's local MJCF frame.
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() < 84:
		return null
	file.seek(80)
	var triangles := file.get_32()
	if triangles == 0 or file.get_length() != 84 + triangles * 50:
		return null
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(triangles):
		var normal := read_vector(file)
		var a := read_vector(file)
		var b := read_vector(file)
		var c := read_vector(file)
		file.get_16()
		# STL is counterclockwise and Godot uses clockwise front faces.
		for vertex in [a, c, b]:
			surface.set_normal(normal)
			surface.add_vertex(vertex)
	surface.index()
	return surface.commit()


func read_vector(file: FileAccess) -> Vector3:
	return Vector3(file.get_float(), file.get_float(), file.get_float())


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or world == null or not world.is_ready() or paused:
		return
	step_budget += delta
	var count := int(step_budget / world.get_timestep())
	if count > 0:
		step_budget -= count * world.get_timestep()
		world.step(count)
		refresh()


func _unhandled_key_input(event: InputEvent) -> void:
	if Engine.is_editor_hint() or world == null or not world.is_ready():
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE:
				paused = not paused
			KEY_R:
				reset()
			KEY_N:
				paused = true
				world.step(1)
		refresh()


func reset() -> void:
	world.reset()
	# Start slightly above the floor and tilted so the unbalanced G1 falls.
	var q := world.get_qpos()
	q[2] += 0.14
	q[3] = cos(0.12)
	q[5] = sin(0.12)
	world.set_qpos(q)
	world.forward()
	step_budget = 0.0
	refresh()


func refresh() -> void:
	var frame: Transform3D = $Robot.global_transform
	# Parents precede children so assigning world poses preserves the articulation.
	for id in links:
		links[id].global_transform = frame * world.body_world_transform(id)
	status.text = " UNITREE G1  |  MUJOCO FALL TEST \n %s  ·  %.2f s  ·  %d contacts \n Space: pause   R: reset   N: step " % [
		"Paused" if paused else "Running", world.get_time(), world.get_ncon()]


func fail(message: String) -> void:
	status.text = message
	push_error(message)
	if "--g1-smoke" in OS.get_cmdline_user_args():
		get_tree().quit(1)


func smoke_test() -> void:
	var pelvis_id := world.body_id("pelvis")
	var initial_height := links[pelvis_id].global_position.y
	world.step(1000)
	refresh()
	var fell := links[pelvis_id].global_position.y < initial_height - 0.2
	var contacts := world.get_ncon() > 0
	reset()
	var reset_ok := is_equal_approx(links[pelvis_id].global_position.y, initial_height)
	if fell and contacts and reset_ok and links.size() == 30:
		print("G1 PASS: 30 links, fall, floor contact and reset")
		get_tree().quit()
	else:
		fail("G1 FAIL: links=%s fall=%s contact=%s reset=%s" % [links.size(), fell, contacts, reset_ok])
