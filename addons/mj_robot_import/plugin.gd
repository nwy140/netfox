@tool
extends EditorPlugin

const Importer = preload("robot_importer.gd")
var source: EditorFileDialog
var result: AcceptDialog


func _enter_tree() -> void:
	source = EditorFileDialog.new()
	source.title = "Import Robot: choose MJCF in its asset folder"
	source.access = EditorFileDialog.ACCESS_RESOURCES
	source.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	source.filters = PackedStringArray(["*.xml ; MJCF model"])
	source.file_selected.connect(import_robot)
	add_child(source)
	result = AcceptDialog.new()
	add_child(result)
	add_tool_menu_item("Import Robot (MuJoCo)", source.popup_centered_ratio.bind(0.65))


func _exit_tree() -> void:
	remove_tool_menu_item("Import Robot (MuJoCo)")
	source.queue_free()
	result.queue_free()


func import_robot(path: String) -> void:
	var importer := Importer.new()
	var target := "res://robot_starter/imported/" + path.get_file().get_basename().validate_filename()
	if importer.save_robot(path, target):
		get_editor_interface().get_resource_filesystem().scan()
		result.dialog_text = "Robot imported into " + target
	else:
		result.dialog_text = importer.error
	result.popup_centered()
