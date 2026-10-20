extends Control
## The network as it ran for the current decision. Left: the 586 numbers it was
## given (one row for the survivor, one per enemy, nearest first). Middle: the two
## hidden layers. Right: what it decided, or how well it thinks it is doing.
## Lines show each neuron's two strongest actual inputs at this moment.

signal input_hovered(row: int)  # -1 none, 0 survivor, 1-18 enemy rows

const POSITIVE := Color("d95926")
const NEGATIVE := Color("3987e5")
const NEUTRAL := Color("383835")
const INK := Color("f0efec")
const INK_2 := Color("c3c2b7")
const MUTED := Color("8c8b84")
const ACTIONS := ["Move X", "Move Z", "Aim X", "Aim Z", "Shoot", "Reload", "Dash"]
const PLAYER_FIELDS := 28
const ENEMY_FIELDS := 31

var result: Dictionary = {}
var applied := PackedFloat32Array()
var player_fields: Array = []
var enemy_fields: Array = []
var note := ""
var archive: RefCounted
var selected := Vector2i(-1, -1)  # (column 1-3, neuron)
var hovered := Vector2i(-1, -1)   # (column 0-3, index)
var font: Font
var lay := {}

func _ready() -> void:
	font = get_theme_default_font()
	mouse_filter = Control.MOUSE_FILTER_STOP
	resized.connect(queue_redraw)
	mouse_exited.connect(func():
		hovered = Vector2i(-1, -1)
		input_hovered.emit(-1)
		queue_redraw())

func show_result(value: Dictionary, applied_action: PackedFloat32Array) -> void:
	if not result.is_empty() and not value.is_empty() and value.branch != result.branch and selected.x == 3:
		selected = Vector2i(-1, -1)
	result = value
	applied = applied_action
	queue_redraw()

static func value_color(v: float) -> Color:
	var t := pow(clampf(absf(v), 0.0, 1.0), 0.6)
	return NEUTRAL.lerp(POSITIVE if v > 0.0 else NEGATIVE, t)

func input_name(i: int) -> String:
	if i < PLAYER_FIELDS:
		return "You · " + str(player_fields[i]).replace("_", " ")
	var slot := (i - PLAYER_FIELDS) / ENEMY_FIELDS + 1
	return "Enemy %d · %s" % [slot, str(enemy_fields[(i - PLAYER_FIELDS) % ENEMY_FIELDS]).replace("_", " ")]

func neuron_name(column: int, index: int) -> String:
	if column == 0:
		return input_name(index)
	if column == 3:
		return ACTIONS[index] if result.branch == "actor" else "Value"
	return "Layer %d · neuron %d" % [column, index + 1]

func _layout() -> void:
	var top := 40.0
	var info := 66.0
	var height := size.y - top - info
	var gx := 40.0
	var out_x := size.x - 150.0
	# The input grid gets most of the width left after the output labels;
	# cells may be taller than wide so each enemy row stays easy to read.
	var cell := clampf(floorf((out_x - gx) * 0.58 / ENEMY_FIELDS) - 1.0, 3.0, 14.0)
	var cell_h := clampf(floorf((height - 40.0) / 19.0) - 1.0, cell, cell * 2.2)
	var rows_height := 19 * (cell_h + 1.0) + 6.0
	var gy := top + 18.0 + (height - 18.0 - rows_height) * 0.4
	var grid_end := gx + ENEMY_FIELDS * (cell + 1.0)
	var rest := out_x - grid_end
	lay = {"top": top, "height": height, "cell": cell, "cell_h": cell_h, "gx": gx, "gy": gy, "grid_end": grid_end,
		"x": [0.0, grid_end + rest * 0.35, grid_end + rest * 0.68, out_x],
		"pitch": height / 128.0, "info_y": size.y - info + 6.0}

func input_rect(i: int) -> Rect2:
	var row := 0 if i < PLAYER_FIELDS else (i - PLAYER_FIELDS) / ENEMY_FIELDS + 1
	var column := i if i < PLAYER_FIELDS else (i - PLAYER_FIELDS) % ENEMY_FIELDS
	var y: float = lay.gy + row * (lay.cell_h + 1.0) + (6.0 if row > 0 else 0.0)
	return Rect2(lay.gx + column * (lay.cell + 1.0), y, lay.cell, lay.cell_h)

func node_position(column: int, index: int) -> Vector2:
	if column == 0:
		return input_rect(index).get_center()
	if column == 3:
		var count: int = 7 if result.branch == "actor" else 1
		var span: float = lay.height * 0.62
		var y: float = lay.top + lay.height * 0.5 + (0.0 if count == 1 else (index / float(count - 1) - 0.5) * span)
		return Vector2(lay.x[3], y)
	return Vector2(lay.x[column], lay.top + (index + 0.5) * lay.pitch)

func _draw() -> void:
	_layout()
	draw_rect(Rect2(Vector2.ZERO, size), Color("1a1a19"))
	if result.is_empty():
		_text(Vector2(14, 60), "No decision to show.", MUTED, 13)
		return
	var actor: bool = result.branch == "actor"
	_text(Vector2(lay.gx - 28.0, lay.gy - 12.0), "What it sees  (one row per enemy, nearest first)", INK_2, 13)
	_text(Vector2(lay.x[1] - 22.0, lay.top - 14.0), "Layer 1", INK_2, 13)
	_text(Vector2(lay.x[2] - 22.0, lay.top - 14.0), "Layer 2", INK_2, 13)
	_text(Vector2(lay.x[3] - 14.0, lay.top - 14.0), "Decision" if actor else "Value", INK_2, 13)
	_draw_connections()
	var layers: Array = result.layers
	var inputs: PackedFloat32Array = layers[0]
	for row in 19:
		var first := 0 if row == 0 else PLAYER_FIELDS + (row - 1) * ENEMY_FIELDS
		var label := "You" if row == 0 else str(row)
		var label_rect := input_rect(first)
		_text(Vector2(lay.gx - 30.0, label_rect.end.y), label, INK_2 if row == 0 or inputs[first] > 0.0 else MUTED, clampi(int(lay.cell_h) + 1, 9, 12))
	for i in 586:
		var rect := input_rect(i)
		var empty_slot := i >= PLAYER_FIELDS and inputs[PLAYER_FIELDS + (i - PLAYER_FIELDS) / ENEMY_FIELDS * ENEMY_FIELDS] == 0.0
		draw_rect(rect, Color(NEUTRAL, 0.35) if empty_slot else value_color(inputs[i]))
	var radius := clampf(lay.pitch * 0.42, 1.0, 2.8)
	for column in [1, 2]:
		var values: PackedFloat32Array = layers[column]
		for o in 128:
			draw_circle(node_position(column, o), radius, value_color(values[o]))
	var outputs: PackedFloat32Array = layers[3]
	for o in outputs.size():
		var point := node_position(3, o)
		draw_circle(point, 6.0, value_color(clampf(outputs[o], -1.0, 1.0)))
		draw_arc(point, 6.0, 0.0, TAU, 24, Color(INK, 0.35), 1.0)
		var name: String = ACTIONS[o] if actor else "Value"
		_text(point + Vector2(12, -2), name, INK_2, 12)
		var detail := "%+.2f" % outputs[o]
		if actor and applied.size() == 7:
			detail = "%+.2f → %+.2f" % [outputs[o], applied[o]]
		_text(point + Vector2(12, 13), detail, MUTED, 11)
	for mark in [hovered, selected]:
		if mark.x >= 0:
			_mark(mark)
	_draw_info()

func _mark(mark: Vector2i) -> void:
	if mark.x == 0:
		draw_rect(input_rect(mark.y).grow(1.5), INK, false, 1.0)
	else:
		draw_arc(node_position(mark.x, mark.y), 8.0 if mark.x == 3 else 4.5, 0.0, TAU, 20, INK, 1.2)

func _contribution(layer: int, i: int, o: int) -> float:
	return result.layers[layer][i] * archive.weight(result, layer, i, o)

func _draw_connections() -> void:
	var layers: Array = result.layers
	if selected.x > 0:
		# Everything flowing into the selected neuron, plus where it sends its signal.
		var layer := selected.x - 1
		var sources: int = layers[layer].size()
		var contributions := PackedFloat32Array()
		contributions.resize(sources)
		var strongest := 0.000001
		for i in sources:
			contributions[i] = _contribution(layer, i, selected.y)
			strongest = maxf(strongest, absf(contributions[i]))
		var target := node_position(selected.x, selected.y)
		for i in sources:
			var share := absf(contributions[i]) / strongest
			if share > 0.04:
				_line(node_position(layer, i), target, contributions[i], share)
		if selected.x < 3:
			var outgoing := []
			var top := 0.000001
			for o in layers[selected.x + 1].size():
				var c := _contribution(selected.x, selected.y, o)
				outgoing.append(c)
				top = maxf(top, absf(c))
			for o in outgoing.size():
				var share: float = absf(outgoing[o]) / top
				if share > 0.15:
					_line(target, node_position(selected.x + 1, o), outgoing[o], share * 0.6)
		return
	# Default view: only the strongest signal paths of this moment.
	for layer in 3:
		var drivers: PackedInt32Array = result.drivers[layer]
		var targets: int = drivers.size() / 2
		var paths := []
		for k in drivers.size():
			if drivers[k] >= 0:
				paths.append([_contribution(layer, drivers[k], k / 2), drivers[k], k / 2])
		paths.sort_custom(func(a, b): return absf(a[0]) > absf(b[0]))
		var shown := mini(paths.size(), 40 if layer < 2 else targets * 3)
		for k in shown:
			var share := absf(paths[k][0]) / maxf(absf(paths[0][0]), 0.000001)
			_line(node_position(layer, paths[k][1]), node_position(layer + 1, paths[k][2]), paths[k][0], share)
		if layer == 2 and targets <= 7:
			# Outputs are few: show their whole fan-in, faintly.
			for o in targets:
				var fan := PackedFloat32Array()
				fan.resize(128)
				var top := 0.000001
				for i in 128:
					fan[i] = _contribution(2, i, o)
					top = maxf(top, absf(fan[i]))
				for i in 128:
					var share := absf(fan[i]) / top
					if share > 0.6:
						_line(node_position(2, i), node_position(3, o), fan[i], share * share * 0.35)

func _line(from: Vector2, to: Vector2, contribution: float, share: float) -> void:
	var color := POSITIVE if contribution > 0.0 else NEGATIVE
	color.a = 0.03 + 0.6 * clampf(share, 0.0, 1.0)
	draw_line(from, to, color, 1.0, true)

func _draw_info() -> void:
	var y: float = lay.info_y
	draw_line(Vector2(14, y - 6), Vector2(size.x - 14, y - 6), Color(INK, 0.08))
	var mark := hovered if hovered.x >= 0 else selected
	if note != "":
		_text(Vector2(14, y + 44), note, POSITIVE, 12)
	if mark.x < 0:
		_text(Vector2(14, y + 14), "Hover a square or a neuron to read it. Click a neuron to trace its signal.", MUTED, 12)
		_text(Vector2(14, y + 32), "Orange pushes up, blue pushes down. Brighter means stronger.", MUTED, 12)
		return
	var value: float = result.layers[mark.x][mark.y]
	_text(Vector2(14, y + 14), "%s   %+.3f" % [neuron_name(mark.x, mark.y), value], INK, 13)
	if mark.x == 0:
		return
	var layer := mark.x - 1
	var ranked := []
	for i in result.layers[layer].size():
		ranked.append([absf(_contribution(layer, i, mark.y)), i])
	ranked.sort_custom(func(a, b): return a[0] > b[0])
	var parts := PackedStringArray()
	for k in 3:
		var i: int = ranked[k][1]
		parts.append("%s (%+.2f)" % [neuron_name(layer, i), _contribution(layer, i, mark.y)])
	_text(Vector2(14, y + 32), "Pushed most by " + ", ".join(parts), MUTED, 12)

func _text(at: Vector2, text: String, color: Color, font_size := 12) -> void:
	draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, size.x - at.x - 10.0, font_size, color)

func _hit(point: Vector2) -> Vector2i:
	if result.is_empty() or lay.is_empty():
		return Vector2i(-1, -1)
	var step: float = lay.cell + 1.0
	var row_step: float = lay.cell_h + 1.0
	if point.x >= lay.gx and point.x < lay.grid_end:
		var column := int((point.x - lay.gx) / step)
		var row := -1
		if point.y >= lay.gy and point.y < lay.gy + row_step:
			row = 0
		elif point.y >= lay.gy + row_step + 6.0:
			row = int((point.y - lay.gy - 6.0) / row_step)
		if row == 0 and column < PLAYER_FIELDS:
			return Vector2i(0, column)
		if row >= 1 and row <= 18:
			return Vector2i(0, PLAYER_FIELDS + (row - 1) * ENEMY_FIELDS + column)
	for column in [1, 2]:
		if absf(point.x - lay.x[column]) < 7.0:
			var index := int((point.y - lay.top) / lay.pitch)
			if index >= 0 and index < 128:
				return Vector2i(column, index)
	for o in result.layers[3].size():
		if point.distance_to(node_position(3, o)) < 11.0:
			return Vector2i(3, o)
	return Vector2i(-1, -1)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var hit := _hit(event.position)
		if hit != hovered:
			hovered = hit
			var row := -1
			if hit.x == 0:
				row = 0 if hit.y < PLAYER_FIELDS else (hit.y - PLAYER_FIELDS) / ENEMY_FIELDS + 1
			input_hovered.emit(row)
			queue_redraw()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var hit := _hit(event.position)
		selected = hit if hit.x > 0 and hit != selected else Vector2i(-1, -1)
		queue_redraw()
