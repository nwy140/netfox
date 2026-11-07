extends RefCounted

# Unitree's single-layer LSTM (47 inputs, 64 states) and 64-32-12 actor.
const HIDDEN := 64
var input_weights: PackedFloat32Array
var recurrent_weights: PackedFloat32Array
var input_bias: PackedFloat32Array
var recurrent_bias: PackedFloat32Array
var actor_weights: PackedFloat32Array
var actor_bias: PackedFloat32Array
var output_weights: PackedFloat32Array
var output_bias: PackedFloat32Array
var hidden := PackedFloat32Array()
var cell := PackedFloat32Array()


func load_weights(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() != 125616:
		return false
	input_weights = file.get_buffer(48128).to_float32_array()
	recurrent_weights = file.get_buffer(65536).to_float32_array()
	input_bias = file.get_buffer(1024).to_float32_array()
	recurrent_bias = file.get_buffer(1024).to_float32_array()
	actor_weights = file.get_buffer(8192).to_float32_array()
	actor_bias = file.get_buffer(128).to_float32_array()
	output_weights = file.get_buffer(1536).to_float32_array()
	output_bias = file.get_buffer(48).to_float32_array()
	reset()
	return true


func reset() -> void:
	hidden.resize(HIDDEN)
	cell.resize(HIDDEN)
	hidden.fill(0.0)
	cell.fill(0.0)


func evaluate(observation: PackedFloat32Array) -> PackedFloat32Array:
	var gates := linear(input_weights, input_bias, observation)
	var recurrent := linear(recurrent_weights, recurrent_bias, hidden)
	for i in range(HIDDEN):
		var input_gate := sigmoid(gates[i] + recurrent[i])
		var forget_gate := sigmoid(gates[i + 64] + recurrent[i + 64])
		var candidate := tanh(gates[i + 128] + recurrent[i + 128])
		var output_gate := sigmoid(gates[i + 192] + recurrent[i + 192])
		cell[i] = forget_gate * cell[i] + input_gate * candidate
		hidden[i] = output_gate * tanh(cell[i])
	var actor := linear(actor_weights, actor_bias, hidden)
	for i in range(actor.size()):
		if actor[i] < 0.0:
			actor[i] = exp(actor[i]) - 1.0
	return linear(output_weights, output_bias, actor)


func linear(weights: PackedFloat32Array, bias: PackedFloat32Array,
		values: PackedFloat32Array) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(bias.size())
	var width := values.size()
	for row in range(result.size()):
		var sum := bias[row]
		var offset := row * width
		for column in range(width):
			sum += weights[offset + column] * values[column]
		result[row] = sum
	return result


func sigmoid(value: float) -> float:
	return 1.0 / (1.0 + exp(-value))
