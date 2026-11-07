extends Resource

# Configuration resources can be shared. Each spawned actor duplicates its motor.
func bind_model(_definition: Resource, _binding: Dictionary) -> bool:
	return false


func apply(_world: MjWorld, _positions: PackedFloat64Array, _velocities: PackedFloat64Array,
		_command: Vector3, _substep: int) -> void:
	pass


func capture() -> Dictionary:
	return {}


func restore(_state: Dictionary) -> void:
	pass
