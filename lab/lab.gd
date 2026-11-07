extends Node3D

const FRAME := Transform3D(Basis(Vector3.RIGHT, -PI / 2.0), Vector3.ZERO)
const STEPS_PER_TICK := 4

var world: MjWorld
var visuals: Dictionary[int, MeshInstance3D]
var camera: Camera3D
var status: Label
var pause_button: Button
var paused := false
var yaw := 0.55
var pitch := 0.35
var distance := 8.0


func _ready() -> void:
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("#202c3c")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color("#a8bad0")
	environment.environment.ambient_light_energy = 0.65
	add_child(environment)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, -30, 0)
	light.shadow_enabled = true
	add_child(light)
	camera = Camera3D.new()
	add_child(camera)
	update_camera()

	var floor_mesh := BoxMesh.new()
	floor_mesh.size = Vector3(16, 0.15, 16)
	make_mesh(floor_mesh, Color("#40536b")).position.y = -0.075
	for i in range(-7, 8):
		var line := BoxMesh.new()
		line.size = Vector3(0.015, 0.004, 16)
		make_mesh(line, Color("#536982")).position.x = i
		var cross := BoxMesh.new()
		cross.size = Vector3(16, 0.004, 0.015)
		make_mesh(cross, Color("#536982")).position.z = i

	build_ui()
	world = MjWorld.new()
	add_child(world)
	if not world.load_model("res://lab/drop_lab.xml"):
		status.text = world.get_last_error()
		push_error(status.text)
		if "--smoke" in OS.get_cmdline_user_args():
			get_tree().quit(1)
		return

	var crate := BoxMesh.new()
	crate.size = Vector3(0.8, 0.8, 0.8)
	var ball := SphereMesh.new()
	ball.radius = 0.38
	ball.height = 0.76
	var block := BoxMesh.new()
	block.size = Vector3(0.7, 0.56, 1.0)
	visuals[world.body_id("crate")] = make_mesh(crate, Color("#ffab59"))
	visuals[world.body_id("ball")] = make_mesh(ball, Color("#59e0d1"))
	visuals[world.body_id("block")] = make_mesh(block, Color("#bd9eff"))
	refresh()
	if "--smoke" in OS.get_cmdline_user_args():
		smoke_test()


func make_mesh(mesh: Mesh, color: Color) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	instance.mesh = mesh
	instance.material_override = material
	add_child(instance)
	return instance


func build_ui() -> void:
	var overlay := CanvasLayer.new()
	add_child(overlay)
	var panel := PanelContainer.new()
	panel.position = Vector2(18, 18)
	overlay.add_child(panel)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 14)
	panel.add_child(margin)
	var column := VBoxContainer.new()
	margin.add_child(column)
	var title := Label.new()
	title.text = "MUJOCO  /  DROP LAB"
	title.add_theme_font_size_override("font_size", 22)
	column.add_child(title)
	status = Label.new()
	column.add_child(status)
	var row := HBoxContainer.new()
	column.add_child(row)
	pause_button = add_button(row, "Pause", toggle_pause)
	add_button(row, "Step", single_step)
	add_button(row, "Reset", reset)
	var hint := Label.new()
	hint.text = "Right drag to orbit • Wheel to zoom"
	column.add_child(hint)


func add_button(row: HBoxContainer, caption: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = caption
	button.pressed.connect(action)
	row.add_child(button)
	return button


func _physics_process(_delta: float) -> void:
	if world != null and world.is_ready() and not paused:
		advance()


func advance() -> void:
	if world.step(STEPS_PER_TICK):
		refresh()


func refresh() -> void:
	for id in visuals:
		visuals[id].transform = FRAME * world.body_world_transform(id) * FRAME.inverse()
	status.text = "MuJoCo %s   |   %.2f s   |   %d contacts" % [
		world.get_mujoco_version(), world.get_time(), world.get_ncon()]


func toggle_pause() -> void:
	paused = not paused
	pause_button.text = "Resume" if paused else "Pause"


func single_step() -> void:
	if world.is_ready():
		if not paused:
			toggle_pause()
		advance()


func reset() -> void:
	if world.is_ready():
		world.reset()
		refresh()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_RIGHT:
		yaw -= event.relative.x * 0.008
		pitch = clampf(pitch + event.relative.y * 0.008, 0.08, 1.45)
		update_camera()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance = maxf(3.0, distance * 0.9)
			update_camera()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			distance = minf(20.0, distance / 0.9)
			update_camera()


func update_camera() -> void:
	var target := Vector3(0, 1.15, 0)
	var offset := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
	camera.look_at_from_position(target + offset * distance, target)


func smoke_test() -> void:
	var ball_id := world.body_id("ball")
	var initial_height := visuals[ball_id].position.y
	single_step()
	var stepped := paused and absf(world.get_time() - 1.0 / 60.0) < 0.00001
	var frozen_time := world.get_time()
	_physics_process(1.0 / 60.0)
	var froze := world.get_time() == frozen_time
	for i in range(180):
		advance()
	var height := visuals[ball_id].position.y
	var landed := height > 0.35 and height < 0.42 and world.get_ncon() > 0
	reset()
	var reset_ok := world.get_time() == 0.0 and is_equal_approx(visuals[ball_id].position.y, initial_height)
	if stepped and froze and landed and reset_ok:
		print("DROP LAB PASS: fixed step, pause, floor contact, pose sync and reset")
		get_tree().quit()
	else:
		push_error("DROP LAB FAIL: step=%s pause=%s contact=%s reset=%s ball_y=%s" % [
			stepped, froze, landed, reset_ok, height])
		get_tree().quit(1)
