@tool
extends RefCounted

const Definition = preload("robot_definition.gd")
const Actor = preload("robot_actor.gd")
const STLReader = preload("res://scripts/unitree_g1.gd")
const FRAME := Transform3D(Basis(Vector3.RIGHT, -PI / 2.0), Vector3.ZERO)
const UNSUPPORTED := ["include", "attach", "frame", "replicate", "flexcomp", "composite",
	"plugin", "texture", "hfield", "skin", "keyframe"]

var error: String


func save_robot(source: String, target: String) -> bool:
	var definition := build_robot(source)
	if definition == null:
		return false
	var definition_path := target.path_join("robot.tres")
	var visual_path := target.path_join("Visuals.scn")
	var actor_path := target.path_join("Robot.tscn")
	if FileAccess.file_exists(definition_path):
		var existing := ResourceLoader.load(definition_path, "", ResourceLoader.CACHE_MODE_IGNORE) as Definition
		if existing == null or existing.model_path != source:
			error = "Output belongs to a different robot. Choose a unique XML filename."
			return false
	if DirAccess.make_dir_recursive_absolute(target) != OK:
		error = "Cannot create " + target
		return false
	if ResourceSaver.save(definition.visuals, visual_path, ResourceSaver.FLAG_COMPRESS) != OK:
		error = "Cannot save " + visual_path
		return false
	definition.visuals.take_over_path(visual_path)
	if ResourceSaver.save(definition, definition_path, ResourceSaver.FLAG_COMPRESS) != OK:
		error = "Cannot save " + definition_path
		return false
	definition.take_over_path(definition_path)
	# The placement scene belongs to the developer after the first import.
	if not FileAccess.file_exists(actor_path):
		var actor := Actor.new()
		actor.name = source.get_file().get_basename().validate_node_name()
		actor.definition = definition
		var preview := definition.visuals.instantiate()
		actor.add_child(preview)
		preview.owner = actor
		var scene := PackedScene.new()
		var result := scene.pack(actor)
		actor.free()
		if result != OK or ResourceSaver.save(scene, actor_path) != OK:
			error = "Cannot save " + actor_path
			return false
	return true


func build_robot(source: String) -> Definition:
	error = ""
	if not source.begins_with("res://"):
		error = "Place the MJCF and its assets inside the project before importing."
		return null
	var parser := XMLParser.new()
	if parser.open(source) != OK:
		error = "Cannot open " + source
		return null
	var definition := Definition.new()
	definition.model_path = source
	var mesh_dir := ""
	var mesh_scales: Dictionary
	var geometry: Array[Dictionary]
	var elements: Array[String]
	var body_stack: Array[String]
	var read_result := parser.read()
	while read_result == OK:
		if parser.get_node_type() == XMLParser.NODE_ELEMENT:
			var tag := parser.get_node_name()
			var parent := "" if elements.is_empty() else elements.back()
			if tag in UNSUPPORTED or (parent.is_empty() and tag != "mujoco"):
				error = "Unsupported MJCF element <%s>. Select a standalone robot model." % tag
				return null
			if tag == "compiler":
				mesh_dir = attr(parser, "meshdir")
			if tag == "mesh" and parent == "asset":
				var mesh_name := attr(parser, "name", attr(parser, "file").get_basename().get_file())
				var file := source.get_base_dir().path_join(mesh_dir).path_join(attr(parser, "file")).simplify_path()
				if not file.begins_with(source.get_base_dir() + "/") or file.get_extension().to_lower() != "stl":
					error = "Mesh %s requires a binary STL inside the MJCF asset folder." % mesh_name
					return null
				if not FileAccess.file_exists(file):
					error = "Missing mesh asset: " + file
					return null
				definition.meshes[mesh_name] = file
				mesh_scales[mesh_name] = vector(attr(parser, "scale", "1 1 1"))
			if tag == "body":
				var body := attr(parser, "name")
				if body.is_empty():
					error = "All robot bodies need explicit names."
					return null
				if parent == "worldbody":
					if not definition.root_body.is_empty():
						error = "Select a model with a single root robot body."
						return null
					definition.root_body = body
				if not parser.is_empty():
					body_stack.append(body)
			if tag == "geom" and parent == "worldbody":
				error = "World geometry belongs in the arena. Select the robot-only MJCF."
				return null
			if tag == "geom" and parent == "body":
				var attributes := {"body": body_stack.back()}
				for i in range(parser.get_attribute_count()):
					attributes[parser.get_attribute_name(i)] = parser.get_attribute_value(i)
				geometry.append(attributes)
			if not parser.is_empty():
				elements.append(tag)
		elif parser.get_node_type() == XMLParser.NODE_ELEMENT_END:
			if parser.get_node_name() == "body":
				body_stack.pop_back()
			elements.pop_back()
		read_result = parser.read()
	if read_result != ERR_FILE_EOF or not elements.is_empty() or definition.root_body.is_empty():
		error = "Expected a complete MJCF document with one root robot body."
		return null
	var world := MjWorld.new()
	if not world.load_model(source):
		error = "MuJoCo could not compile the model: " + world.get_last_error()
		world.free()
		return null
	definition.position_count = world.get_nq()
	definition.velocity_count = world.get_nv()
	var ok := capture_visuals(definition, world, geometry, mesh_scales)
	world.free()
	return definition if ok else null


func capture_visuals(definition: Definition, world: MjWorld, geometry: Array[Dictionary],
		mesh_scales: Dictionary) -> bool:
	var preview := Node3D.new()
	preview.name = "Visuals"
	var links: Dictionary[String, Node3D]
	var stl := STLReader.new()
	var cache: Dictionary[String, Mesh]
	for id in range(1, world.get_nbody()):
		var body := world.body_name(id)
		var link := Node3D.new()
		link.name = "Link%d" % id
		link.set_meta("mj_body", body)
		link.transform = FRAME * world.body_world_transform(id)
		preview.add_child(link)
		link.owner = preview
		links[body] = link
		definition.bodies.append(body)
	for id in range(world.get_njnt()):
		definition.joints.append(world.joint_name(id))
	for id in range(world.get_nu()):
		definition.actuators.append(world.actuator_name(id))
	if definition.joints.has("") or definition.actuators.has(""):
		error = "All joints and actuators need explicit names."
	for geom in geometry:
		if not error.is_empty():
			break
		var shape: String = geom.get("type", "sphere")
		var mesh: Mesh
		var mesh_scale := Vector3.ONE
		if shape == "mesh":
			var key: String = geom.get("mesh", "")
			if not cache.has(key) and definition.meshes.has(key):
				cache[key] = stl.load_stl(definition.meshes[key])
			mesh = cache.get(key)
			mesh_scale = mesh_scales.get(key, Vector3.ONE)
		else:
			mesh = primitive(shape, vector(geom.get("size", "")))
		if mesh == null or geom.has("fromto") or geom.has("euler") or geom.has("axisangle") \
				or geom.has("xyaxes") or geom.has("zaxis") or geom.has("material") or geom.has("class"):
			error = "Unsupported visual on %s. Use explicit mesh/primitive geometry with pos and quat." % geom.body
			break
		var visual := MeshInstance3D.new()
		visual.name = "Shape%d" % links[geom.body].get_child_count()
		visual.mesh = mesh
		var material := StandardMaterial3D.new()
		var rgba: PackedStringArray = str(geom.get("rgba", "0.6 0.6 0.6 1")).split(" ", false)
		if rgba.size() == 4:
			material.albedo_color = Color(rgba[0].to_float(), rgba[1].to_float(), rgba[2].to_float(), rgba[3].to_float())
		visual.material_override = material
		var rotation := quat(geom.get("quat", "1 0 0 0"))
		var basis := Basis(rotation)
		if shape == "capsule" or shape == "cylinder":
			basis *= Basis(Vector3.RIGHT, PI / 2.0)
		visual.transform = Transform3D(basis.scaled_local(mesh_scale), vector(geom.get("pos", "")))
		links[geom.body].add_child(visual)
		visual.owner = preview
	stl.free()
	if error.is_empty():
		definition.visuals = PackedScene.new()
		if definition.visuals.pack(preview) != OK:
			error = "Could not pack generated robot visuals."
	preview.free()
	return error.is_empty()


func primitive(shape: String, size: Vector3) -> Mesh:
	match shape:
		"sphere":
			var mesh := SphereMesh.new()
			mesh.radius = size.x
			mesh.height = size.x * 2.0
			return mesh
		"box":
			var mesh := BoxMesh.new()
			mesh.size = size * 2.0
			return mesh
		"cylinder":
			var mesh := CylinderMesh.new()
			mesh.top_radius = size.x
			mesh.bottom_radius = size.x
			mesh.height = size.y * 2.0
			return mesh
		"capsule":
			var mesh := CapsuleMesh.new()
			mesh.radius = size.x
			mesh.height = (size.x + size.y) * 2.0
			return mesh
	return null


func attr(parser: XMLParser, key: String, fallback: String = "") -> String:
	return parser.get_named_attribute_value(key) if parser.has_attribute(key) else fallback


func vector(value: String) -> Vector3:
	var values := value.split(" ", false)
	var result := Vector3.ZERO
	for i in range(mini(3, values.size())):
		result[i] = values[i].to_float()
	return result


func quat(value: String) -> Quaternion:
	var values := value.split(" ", false)
	if values.size() != 4:
		return Quaternion.IDENTITY
	return Quaternion(values[1].to_float(), values[2].to_float(), values[3].to_float(), values[0].to_float()).normalized()
