@tool
extends Resource

@export_file("*.xml") var model_path: String
@export var root_body: String
@export var position_count: int
@export var velocity_count: int
@export var bodies: PackedStringArray
@export var joints: PackedStringArray
@export var actuators: PackedStringArray
@export var meshes: Dictionary[String, String]
@export var visuals: PackedScene
