extends Control
## Native Godot neuron display. All numbers come from verified saved inference.
const AMBER := Color("e7b655")
const BLUE := Color("83b6b0")
const INK := Color("dedbc2")
const MUTED := Color("9ea38b")
const ACTIONS := ["MOVE X", "MOVE Z", "AIM X", "AIM Z", "SHOOT", "RELOAD", "DASH"]
var decision: Dictionary = {}
var policies: Dictionary = {}
var branch := "actor"
var selected_layer := 1
var selected_neuron := 42
var hits: Array = []
var player_fields: Array = []
var enemy_fields: Array = []
var font: Font
var draw_scale := Vector2.ONE

func _ready() -> void:
	font = get_theme_default_font()
	custom_minimum_size = Vector2(620, 660)
	mouse_filter = Control.MOUSE_FILTER_STOP
	resized.connect(queue_redraw)

func set_branch(value: String) -> void:
	branch = value
	if branch == "critic" and selected_layer == 2:
		selected_neuron = 0
	queue_redraw()

func input_name(index: int) -> String:
	if index < 28:
		return player_fields[index] if player_fields.size() > index else str(index)
	var slot := (index - 28) / 31
	var field := (index - 28) % 31
	return "Enemy %d / %s" % [slot + 1, enemy_fields[field]]

func text_at(point: Vector2, text: String, color := INK, font_size := 12) -> void:
	draw_string(font, point, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)

func layer_positions() -> Array:
	var inputs: Array = []
	for index in range(586):
		inputs.append(Vector2(20 + (index % 14) * 7, 101 + (index / 14) * 6))
	var first: Array = []
	var second: Array = []
	for index in range(128):
		first.append(Vector2(198 + (index % 8) * 13, 126 + (index / 8) * 13))
		second.append(Vector2(370 + (index % 8) * 13, 126 + (index / 8) * 13))
	var outputs: Array = []
	for index in range(7 if branch == "actor" else 1):
		outputs.append(Vector2(542, 145 + index * 27 if branch == "actor" else 235))
	return [inputs, first, second, outputs]

func _draw() -> void:
	if not font:
		return
	draw_scale = Vector2(size.x / 620.0, size.y / 720.0)
	draw_set_transform(Vector2.ZERO, 0.0, draw_scale)
	draw_rect(Rect2(0, 0, 620, 720), Color("20251e"))
	for x in range(0, 621, 20):
		draw_line(Vector2(x, 47), Vector2(x, 370), Color("293026"))
	for y in range(47, 370, 20):
		draw_line(Vector2(0, y), Vector2(620, y), Color("293026"))
	text_at(Vector2(18, 24), "02 / NEURAL ACTIVITY", AMBER, 15)
	text_at(Vector2(18, 43), "ACTUAL ACTIVATIONS / SELECT A NEURON", MUTED, 10)
	text_at(Vector2(18, 71), "INPUTS", INK, 12)
	text_at(Vector2(198, 71), "HIDDEN 1", INK, 12)
	text_at(Vector2(370, 71), "HIDDEN 2", INK, 12)
	text_at(Vector2(524, 71), "MEANS" if branch == "actor" else "VALUE", INK, 12)
	text_at(Vector2(18, 86), "586 / v2", MUTED, 10)
	text_at(Vector2(198, 86), "128 / TANH", MUTED, 10)
	text_at(Vector2(370, 86), "128 / TANH", MUTED, 10)
	hits.clear()
	if decision.is_empty():
		text_at(Vector2(160, 230), "FINAL STATE / NO NEW DECISION", INK, 15)
		return
	var hidden: Array = decision.activations[branch]
	var values := [decision.observation, hidden[0], hidden[1], decision.mean if branch == "actor" else [decision.value]]
	var positions := layer_positions()
	var layer: Dictionary = policies[decision.policy_id][branch][selected_layer]
	var incoming: Array = layer.weights[selected_neuron]
	var bias: float = layer.biases[selected_neuron]
	var strongest := 0.001
	for weight in incoming:
		strongest = maxf(strongest, absf(weight))
	var target: Vector2 = positions[selected_layer + 1][selected_neuron]
	for index in range(incoming.size()):
		var weight: float = incoming[index]
		var color := AMBER if weight >= 0.0 else BLUE
		color.a = 0.03 + absf(weight) / strongest * 0.36
		draw_line(positions[selected_layer][index], target, color, 0.5 + absf(weight) / strongest, false)
	for column in range(positions.size()):
		for index in range(positions[column].size()):
			var value: float = values[column][index]
			var point: Vector2 = positions[column][index]
			var color := AMBER if value >= 0.0 else BLUE
			color.a = 0.15 + minf(absf(value), 1.0) * 0.85
			if column == 0:
				draw_rect(Rect2(point - Vector2.ONE * 1.8, Vector2.ONE * 3.6), color)
			else:
				draw_circle(point, 5 if column == 3 else 3.6, color, true, -1, false)
			if column == selected_layer + 1 and index == selected_neuron:
				draw_rect(Rect2(point - Vector2.ONE * 6.5, Vector2.ONE * 13), INK, false, 1)
			hits.append({"point": point, "layer": column, "index": index, "value": value})
			if column == 3 and branch == "actor":
				text_at(point + Vector2(10, 3), ACTIONS[index], MUTED, 9)
	text_at(Vector2(18, 373), "+ AMBER  /  - BLUE  /  BRIGHTNESS = MAGNITUDE", MUTED, 10)
	draw_line(Vector2(18, 390), Vector2(602, 390), Color("505441"))
	text_at(Vector2(18, 416), "03 / ACTUAL COMMANDS", AMBER, 13)
	for index in range(7):
		var left := 18.0 + index * 84.0
		var value: float = decision.action[index]
		text_at(Vector2(left, 438), ACTIONS[index], MUTED, 10)
		draw_rect(Rect2(left, 446, 68, 5), Color("131a11"))
		draw_rect(Rect2(left + 34 + minf(value, 0) * 34, 446, absf(value) * 34, 5), AMBER if value >= 0 else BLUE)
		text_at(Vector2(left, 469), "%+.2f" % value, INK, 12)
	text_at(Vector2(18, 492), "Means -> random sample -> clipping -> game commands", MUTED, 10)
	draw_line(Vector2(18, 505), Vector2(602, 505), Color("505441"))
	text_at(Vector2(18, 532), "04 / SIGNAL INSPECTOR", AMBER, 13)
	text_at(Vector2(18, 553), "%s / %s %d / NEURON %d" % [branch.to_upper(), "OUTPUT" if selected_layer == 2 else "HIDDEN", selected_layer + 1, selected_neuron], INK, 11)
	var activation: float = values[selected_layer + 1][selected_neuron]
	text_at(Vector2(18, 574), "Activation: %+.5f   Bias: %+.5f" % [activation, bias], INK, 11)
	var contributions: Array = []
	for index in range(incoming.size()):
		contributions.append({"index": index, "value": incoming[index] * values[selected_layer][index], "weight": incoming[index]})
	contributions.sort_custom(func(a, b): return absf(a.value) > absf(b.value))
	for rank in range(2):
		var entry: Dictionary = contributions[rank]
		var label := input_name(entry.index) if selected_layer == 0 else "Previous neuron %d" % entry.index
		text_at(Vector2(18, 595 + rank * 18), "%s: w=%+.4f / contribution=%+.4f" % [label, entry.weight, entry.value], MUTED, 10)
	draw_line(Vector2(18, 625), Vector2(602, 625), Color("505441"))
	text_at(Vector2(18, 650), "05 / VERIFIED LIVE INFERENCE" if decision.verified else "05 / INFERENCE MISMATCH", Color("b8c48c") if decision.verified else Color("ed9175"), 13)
	text_at(Vector2(18, 670), "Value %.4f | Error: value %.7f / log-prob %.7f" % [decision.value, decision.value_error, decision.log_prob_error], MUTED, 10)
	text_at(Vector2(18, 689), "Weights @ decision %d / SHA256 %s..." % [decision.policy_timestep, decision.policy_id.substr(0, 22)], MUTED, 10)
	text_at(Vector2(18, 709), "Neuron activity is measured; its meaning is not labelled.", MUTED, 10)

func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseMotion or event is InputEventMouseButton):
		return
	var local: Vector2 = event.position / draw_scale
	tooltip_text = ""
	for hit in hits:
		if local.distance_to(hit.point) < (7 if hit.layer else 4):
			tooltip_text = (input_name(hit.index) if hit.layer == 0 else "Layer %d / neuron %d" % [hit.layer, hit.index]) + " = %.6f" % hit.value
			if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and hit.layer > 0:
				selected_layer = hit.layer - 1
				selected_neuron = hit.index
				queue_redraw()
			break
