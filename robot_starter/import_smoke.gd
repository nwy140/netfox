extends SceneTree

const Importer = preload("res://addons/mj_robot_import/robot_importer.gd")
const MODELS := ["res://models/g1_walk/g1_12dof.xml", "res://robot_starter/models/rover/rover.xml"]


func _initialize() -> void:
	run.call_deferred()


func run() -> void:
	for source in MODELS:
		var importer := Importer.new()
		var folder: String = "user://robot_import_smoke_v2/" + source.get_file().get_basename()
		if not importer.save_robot(source, folder):
			push_error(importer.error)
			quit(1)
			return
		var actor_path := folder.path_join("Robot.tscn")
		var original := FileAccess.get_sha256(actor_path)
		if not importer.save_robot(source, folder) or FileAccess.get_sha256(actor_path) != original:
			push_error("Reimport did not preserve the placement scene.")
			quit(1)
			return
		var scene := load(actor_path) as PackedScene
		var actor := scene.instantiate()
		print("ROBOT IMPORT PASS %s bodies=%d joints=%d actuators=%d meshes=%d" % [
			source, actor.definition.bodies.size(), actor.definition.joints.size(),
			actor.definition.actuators.size(), actor.definition.meshes.size()])
		actor.free()
	quit()
