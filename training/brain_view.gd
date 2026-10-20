extends Control
## The network at the current decision, drawn like an LED panel: the 590 inputs
## (a row for the survivor, then one per enemy, nearest first), both hidden
## layers as 16x8 blocks, and the outputs as meters. Click a neuron to outline
## the inputs that drove it.

signal input_hovered(row: int)  # -1 none, 0 survivor, 1-18 enemy rows
signal branch_chosen(branch: String)

const Style := preload("res://training/replay_style.gd")
const ACTIONS := ["MOVE X", "MOVE Z", "MOUSE X", "MOUSE Z", "FIRE", "RELOAD", "DASH"]
const ENEMY_FIELDS := 31
const SLOTS := 18
const TRACE := 8
const TAB_SPLIT := 120.0

var archive: RefCounted
var result: Dictionary = {}
var applied := PackedFloat32Array()
var values := PackedFloat32Array()   # recorded critic value for every decision
var head := 0.0
var player_fields: Array = []
var enemy_fields: Array = []
var note := ""
var selected := Vector2i(-1, -1)  # (column 1-3, index)
var hovered := Vector2i(-1, -1)   # (column 0-3, index)
var lay := {}

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	resized.connect(queue_redraw)
	mouse_exited.connect(func():
		hovered = Vector2i(-1, -1)
		input_hovered.emit(-1)
		queue_redraw())

func show_result(value: Dictionary, applied_action: PackedFloat32Array) -> void:
	if not result.is_empty() and not value.is_empty() and value.branch != result.branch:
		selected = Vector2i(-1, -1)
	result = value
	applied = applied_action
	queue_redraw()

func _layout() -> void:
	var w := size.x
	var label_w := Style.width_of("RELOAD") + 10.0
	var out_w := label_w + 56.0
	var columns := maxi(player_fields.size(), ENEMY_FIELDS)
	var step := clampf(floorf((w - 24.0 - out_w - 34.0) / (columns + 16)), 4.0, 10.0)
	var top := 58.0
	var grid_h := 19 * step + 3.0
	# Output rows shrink on short panels so the value strip always fits below.
	var row_h := clampf(floorf((size.y - top - 60.0) / 7.0), 14.0, 20.0)
	var content_bottom := top + maxf(grid_h, (grid_h + 7.0 * row_h) * 0.5)
	var x0 := 12.0
	var l1 := x0 + columns * step + 12.0
	var l2 := l1 + 8 * step + 10.0
	var out := l2 + 8 * step + 14.0
	lay = {"step": step, "top": top, "grid_h": grid_h, "x": [x0, l1, l2, out], "label_w": label_w,
		"layer_y": top + (grid_h - 16 * step) * 0.5, "out_w": w - out - 12.0, "row_h": row_h,
		"spark": Rect2(12, maxf(content_bottom + 30.0, size.y - 40.0), w - 24, 26)}
	# Hover/warning text shares the strip's label line, so small panels still fit.
	lay["hover_y"] = lay.spark.position.y - 8.0

func cell(column: int, index: int) -> Rect2:
	var step: float = lay.step
	if column == 0:
		var row := 0 if index < player_fields.size() else (index - player_fields.size()) / ENEMY_FIELDS + 1
		var col := index if index < player_fields.size() else (index - player_fields.size()) % ENEMY_FIELDS
		return Rect2(lay.x[0] + col * step, lay.top + row * step + (3.0 if row > 0 else 0.0), step - 1, step - 1)
	if column < 3:
		return Rect2(lay.x[column] + (index % 8) * step, lay.layer_y + (index / 8) * step, step - 1, step - 1)
	var count: int = result.layers[3].size()
	var row_h: float = lay.row_h
	var y: float = lay.top + (lay.grid_h - count * row_h) * 0.5 + index * row_h
	return Rect2(lay.x[3], y, lay.out_w, row_h - 3)

func _draw() -> void:
	_layout()
	draw_rect(Rect2(Vector2.ZERO, size), Style.BG)
	var actor: bool = result.is_empty() or result.branch == "actor"
	Style.text(self, Vector2(12, 26), "POLICY", 16, Style.TEXT if actor else Style.DIM, true)
	Style.text(self, Vector2(TAB_SPLIT, 26), "VALUE", 16, Style.DIM if actor else Style.TEXT, true)
	draw_rect(Rect2(12 if actor else TAB_SPLIT, 31, Style.width_of("POLICY" if actor else "VALUE", 16, true), 2), Style.TEXT)
	if result.is_empty():
		return
	Style.text(self, Vector2(lay.x[0], lay.top - 8), "INPUT", 16, Style.DIM)
	Style.text(self, Vector2(lay.x[1], lay.layer_y - 8), "L1", 16, Style.DIM)
	Style.text(self, Vector2(lay.x[2], lay.layer_y - 8), "L2", 16, Style.DIM)
	var layers: Array = result.layers
	var inputs: PackedFloat32Array = layers[0]
	for i in player_fields.size() + SLOTS * ENEMY_FIELDS:
		var slot_present := i < player_fields.size() or inputs[player_fields.size() + (i - player_fields.size()) / ENEMY_FIELDS * ENEMY_FIELDS] != 0.0
		draw_rect(cell(0, i), Style.led(inputs[i]) if slot_present else Color(Style.ZERO, 0.5))
	for column in [1, 2]:
		var activations: PackedFloat32Array = layers[column]
		for o in 128:
			draw_rect(cell(column, o), Style.led(activations[o]))
	var outputs: PackedFloat32Array = layers[3]
	for o in outputs.size():
		var rect := cell(3, o)
		var label: String = ACTIONS[o] if actor else "VALUE"
		Style.text(self, Vector2(rect.position.x, rect.end.y - 2), label, 16, Style.DIM)
		var bar := Rect2(rect.position.x + lay.label_w, rect.position.y + 4, rect.size.x - lay.label_w, rect.size.y - 8)
		draw_rect(bar, Style.ZERO)
		var middle := bar.position.x + bar.size.x * 0.5
		var amount := clampf(outputs[o], -1.0, 1.0) * bar.size.x * 0.5
		draw_rect(Rect2(minf(middle, middle + amount), bar.position.y, absf(amount), bar.size.y), Style.led(outputs[o]))
		draw_line(Vector2(middle, bar.position.y - 1), Vector2(middle, bar.end.y + 1), Style.DIM)
		if actor and applied.size() == 7:
			var sent := middle + clampf(applied[o], -1.0, 1.0) * bar.size.x * 0.5
			draw_rect(Rect2(sent - 1, bar.position.y - 2, 2, bar.size.y + 4), Style.TEXT)
	if selected.x > 0:
		for source in _strongest_sources(selected.x, selected.y):
			draw_rect(cell(selected.x - 1, source).grow(1), Style.TEXT, false, 1.0)
		draw_rect(cell(selected.x, selected.y).grow(1), Style.GOLD, false, 1.0)
	if hovered.x >= 0:
		draw_rect(cell(hovered.x, hovered.y).grow(1), Style.TEXT, false, 1.0)
	_draw_value_strip()
	if note != "":
		Style.text(self, Vector2(12, lay.hover_y), note, 16, Style.BEHIND)
	elif hovered.x >= 0:
		Style.text(self, Vector2(12, lay.hover_y), _describe(hovered), 16, Style.TEXT)

func _draw_value_strip() -> void:
	var strip: Rect2 = lay.spark
	if hovered.x < 0 and note == "":
		Style.text(self, strip.position - Vector2(0, 8), "VALUE", 16, Style.DIM)
	draw_rect(strip, Style.ZERO)
	if values.size() < 2:
		return
	var low := values[0]
	var high := values[0]
	for v in values:
		low = minf(low, v)
		high = maxf(high, v)
	var span := maxf(high - low, 0.001)
	var points := PackedVector2Array()
	for i in values.size():
		points.append(Vector2(strip.position.x + strip.size.x * i / float(values.size() - 1),
			strip.end.y - 2.0 - (strip.size.y - 4.0) * (values[i] - low) / span))
	draw_polyline(points, Style.OFF, 1.0)
	var x := strip.position.x + strip.size.x * clampf(head / float(values.size()), 0.0, 1.0)
	draw_line(Vector2(x, strip.position.y), Vector2(x, strip.end.y), Style.TEXT, 1.0)
	var i := clampi(int(head), 0, values.size() - 1)
	if hovered.x < 0 and note == "":
		Style.text(self, Vector2(strip.end.x, strip.position.y - 8), "%+.2f" % values[i], 16, Style.TEXT, false, HORIZONTAL_ALIGNMENT_RIGHT)

func _strongest_sources(column: int, index: int) -> Array:
	var layer := column - 1
	var ranked := []
	var sources: PackedFloat32Array = result.layers[layer]
	for i in sources.size():
		if sources[i] != 0.0:
			ranked.append([absf(sources[i] * archive.weight(result, layer, i, index)), i])
	ranked.sort_custom(func(a, b): return a[0] > b[0])
	return ranked.slice(0, TRACE).map(func(entry): return entry[1])

func _describe(mark: Vector2i) -> String:
	var value: float = result.layers[mark.x][mark.y]
	if mark.x == 0:
		var name: String
		if mark.y < player_fields.size():
			name = "YOU  " + str(player_fields[mark.y])
		else:
			var slot := (mark.y - player_fields.size()) / ENEMY_FIELDS + 1
			name = "ENEMY %d  %s" % [slot, enemy_fields[(mark.y - player_fields.size()) % ENEMY_FIELDS]]
		return "%s  %+.3f" % [name.replace("_", " ").to_upper(), value]
	if mark.x < 3:
		return "L%d NEURON %d  %+.3f" % [mark.x, mark.y + 1, value]
	if result.branch != "actor":
		return "EXPECTED REWARD  %+.3f" % value
	return "%s  WANTS %+.2f  SENT %+.2f" % [ACTIONS[mark.y], value, applied[mark.y]]

func _hit(point: Vector2) -> Vector2i:
	if result.is_empty() or lay.is_empty():
		return Vector2i(-1, -1)
	for column in 4:
		var count: int = [result.layers[0].size(), 128, 128, result.layers[3].size()][column]
		for i in count:
			if cell(column, i).grow(0.5).has_point(point):
				return Vector2i(column, i)
	return Vector2i(-1, -1)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var hit := _hit(event.position)
		if hit != hovered:
			hovered = hit
			var row := -1
			if hit.x == 0:
				row = 0 if hit.y < player_fields.size() else (hit.y - player_fields.size()) / ENEMY_FIELDS + 1
			input_hovered.emit(row)
			queue_redraw()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if event.position.y < 40.0:
			branch_chosen.emit("actor" if event.position.x < TAB_SPLIT - 8 else "critic")
			return
		var hit := _hit(event.position)
		selected = hit if hit.x > 0 and hit != selected else Vector2i(-1, -1)
		queue_redraw()
