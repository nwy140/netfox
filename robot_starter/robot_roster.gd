extends RefCounted

const Definition = preload("res://addons/mj_robot_import/robot_definition.gd")

var error: String
var bindings: Dictionary


func compile(world: MjWorld, roster: Array[Dictionary]) -> bool:
	error = ""
	bindings.clear()
	var folder := "user://robot_match_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	if DirAccess.make_dir_recursive_absolute(folder) != OK:
		error = "Cannot prepare MuJoCo model files."
		return false
	var assets := ""
	var instances := ""
	var position_offset := 0
	var velocity_offset := 0
	var files: PackedStringArray
	var directories: PackedStringArray
	for entry in roster:
		var definition: Definition = entry.definition
		var id: String = entry.id
		if definition == null or not id.is_valid_identifier() or bindings.has(id):
			error = "Each placed robot needs a definition and a unique identifier."
			break
		var prefix := id + "__"
		var model_folder := folder.path_join(id)
		if DirAccess.make_dir_absolute(model_folder) != OK:
			error = "Cannot prepare model folder for " + id
			break
		directories.append(model_folder)
		var model_path := model_folder.path_join(definition.model_path.get_file())
		if not stage_file(definition.model_path, model_path, files, directories):
			break
		for source in definition.meshes.values():
			var relative: String = source.trim_prefix(definition.model_path.get_base_dir() + "/")
			if not stage_file(source, model_folder.path_join(relative), files, directories):
				break
		if not error.is_empty():
			break
		var pos: Vector3 = entry.position
		var yaw: float = entry.get("yaw", 0.0)
		assets += '<model name="%s" file="%s/%s"/>' % [
			id, id, definition.model_path.get_file().xml_escape(true)]
		instances += '<frame pos="%s %s %s" quat="%s 0 0 %s"><attach model="%s" body="%s" prefix="%s"/></frame>' % [
			pos.x, -pos.z, pos.y, cos(yaw / 2.0), sin(yaw / 2.0), id,
			definition.root_body.xml_escape(true), prefix]
		bindings[id] = {"prefix": prefix, "bodies": {}, "joints": {}, "actuators": {},
			"position_offset": position_offset, "velocity_offset": velocity_offset}
		position_offset += definition.position_count
		velocity_offset += definition.velocity_count
	var arena_path := folder.path_join("arena.xml")
	if error.is_empty():
		var xml := '<mujoco model="robot_starter"><compiler angle="radian"/>' \
			+ '<option timestep="0.002" integrator="implicitfast"/><asset>%s</asset>' % assets \
			+ '<worldbody><geom name="ground" type="plane" size="0 0 0.05"/>%s</worldbody></mujoco>' % instances
		var file := FileAccess.open(arena_path, FileAccess.WRITE)
		if file == null:
			error = "Cannot write MuJoCo arena."
		else:
			file.store_string(xml)
			file.close()
			files.append(arena_path)
			if not world.load_model(arena_path):
				error = world.get_last_error()
	for path in files:
		DirAccess.remove_absolute(path)
	for i in range(directories.size() - 1, -1, -1):
		DirAccess.remove_absolute(directories[i])
	DirAccess.remove_absolute(folder)
	if not error.is_empty():
		bindings.clear()
		return false
	if world.get_nq() != position_offset or world.get_nv() != velocity_offset:
		error = "Robot model layout changed. Reimport the MJCF files."
		bindings.clear()
		return false
	for entry in roster:
		var definition: Definition = entry.definition
		var binding: Dictionary = bindings[entry.id]
		for name in definition.bodies:
			binding.bodies[name] = world.body_id(binding.prefix + name)
		for name in definition.joints:
			binding.joints[name] = world.joint_id(binding.prefix + name)
		for name in definition.actuators:
			binding.actuators[name] = world.actuator_id(binding.prefix + name)
		for ids in [binding.bodies, binding.joints, binding.actuators]:
			if -1 in ids.values():
				error = "Missing compiled binding. Reimport the MJCF files."
				bindings.clear()
				return false
	return true


func stage_file(source: String, destination: String, files: PackedStringArray, directories: PackedStringArray) -> bool:
	var parent := destination.get_base_dir()
	var missing: PackedStringArray
	while not DirAccess.dir_exists_absolute(parent):
		missing.append(parent)
		parent = parent.get_base_dir()
	if DirAccess.make_dir_recursive_absolute(destination.get_base_dir()) != OK:
		error = "Cannot prepare " + destination.get_base_dir()
		return false
	for i in range(missing.size() - 1, -1, -1):
		directories.append(missing[i])
	var bytes := FileAccess.get_file_as_bytes(source)
	var file := FileAccess.open(destination, FileAccess.WRITE)
	if file != null:
		files.append(destination)
	if file == null or bytes.is_empty():
		error = "Cannot stage asset " + source
		return false
	file.store_buffer(bytes)
	return true
