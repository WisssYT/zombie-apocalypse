extends Control
## Every recorded attempt across all training sessions, in training order.
## Click one to watch it.

signal chosen(index: int)
signal open_folder

const Style := preload("res://training/replay_style.gd")
const METRICS := ["seconds", "kills", "collisions", "fell_off", "reward"]
const NAMES := {"seconds": "TIME", "kills": "KILLS", "collisions": "COLLISIONS", "fell_off": "FELL OFF", "reward": "REWARD"}
const PAPER := Color("0b0b0c")

var rows: Array = []
var current := -1
var metric := "seconds"
var source := ""
var message := ""
var hover := -1

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	resized.connect(queue_redraw)

func set_metric(key: String) -> void:
	metric = key
	queue_redraw()

func _toggles() -> Dictionary:
	var result := {}
	var x := 24.0
	for key in METRICS:
		var width := Style.width_of(NAMES[key], 16, true) + 28.0
		result[key] = Rect2(x, 72, width, 28)
		x += width + 8.0
	result["folder"] = Rect2(size.x - 204, 72, 180, 28)
	return result

func _chart() -> Rect2:
	return Rect2(84, 150, size.x - 116, size.y - 210)

func _x_value(row: Dictionary) -> float:
	return float(row.get("timestep", row.number))

func _range() -> Array:
	var low := INF
	var high := -INF
	var top := 0.0
	var bottom := 0.0
	for row in rows:
		low = minf(low, _x_value(row))
		high = maxf(high, _x_value(row))
		top = maxf(top, float(row.get(metric, 0)))
		bottom = minf(bottom, float(row.get(metric, 0)))
	if high <= low:
		high = low + 1.0
	# Round tick steps (1, 2 or 5 x 10^n), with headroom above the best attempt.
	top *= 1.1
	var raw := maxf(top - bottom, 1.0) / 4.0
	var magnitude := pow(10.0, floorf(log(raw) / log(10.0)))
	var tick := magnitude * (1.0 if raw <= magnitude else 2.0 if raw <= 2.0 * magnitude else 5.0 if raw <= 5.0 * magnitude else 10.0)
	return [low, high, floorf(bottom / tick) * tick, ceilf(top / tick) * tick, tick]

func _point(row: Dictionary, bounds: Array) -> Vector2:
	var chart := _chart()
	return Vector2(chart.position.x + chart.size.x * (_x_value(row) - bounds[0]) / (bounds[1] - bounds[0]),
		chart.end.y - chart.size.y * (float(row.get(metric, 0)) - bounds[2]) / (bounds[3] - bounds[2])).round()

func _color(row: Dictionary) -> Color:
	return Style.BEHIND if row.status == "died" else Style.GOLD if row.status == "timeout" else Style.DIM

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), PAPER)
	Style.text(self, Vector2(24, 52), "ATTEMPTS", 48, Style.TEXT, true)
	var summary := message.to_upper()
	if rows.size() > 0:
		summary = "%d RUNS   %s STEPS   %s" % [rows.size(), Style.steps(_x_value(rows.back())),
			source.trim_suffix("/").get_file().to_upper()]
	Style.text(self, Vector2(Style.width_of("ATTEMPTS", 48, true) + 48, 48), summary, 16, Style.DIM)
	var toggles := _toggles()
	for key in METRICS:
		var rect: Rect2 = toggles[key]
		if key == metric:
			draw_rect(rect, Style.TEXT)
		Style.text(self, Vector2(rect.position.x, rect.position.y + 20), NAMES[key], 16,
			Color("111111") if key == metric else Style.TEXT, true, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x)
	var folder: Rect2 = toggles.folder
	draw_rect(folder, Color(Style.TEXT, 0.3), false, 1.0)
	Style.text(self, Vector2(folder.position.x, folder.position.y + 20), "OPEN FOLDER", 16, Style.TEXT, true,
		HORIZONTAL_ALIGNMENT_CENTER, folder.size.x)
	if rows.is_empty():
		return
	var chart := _chart()
	var bounds := _range()
	var ticks := roundi((bounds[3] - bounds[2]) / bounds[4])
	for k in ticks + 1:
		var value: float = bounds[2] + bounds[4] * k
		var y := roundf(chart.end.y - chart.size.y * k / float(ticks))
		draw_line(Vector2(chart.position.x, y), Vector2(chart.end.x, y), Color(Style.TEXT, 0.18 if is_zero_approx(value) else 0.05))
		Style.text(self, Vector2(chart.position.x - 12, y + 6), "%.0f" % value if bounds[4] >= 1.0 else "%.1f" % value,
			16, Style.DIM, false, HORIZONTAL_ALIGNMENT_RIGHT)
	for k in 5:
		var x := chart.position.x + chart.size.x * k / 4.0
		Style.text(self, Vector2(x - 60, chart.end.y + 26), Style.steps(bounds[0] + (bounds[1] - bounds[0]) * k / 4.0),
			16, Style.DIM, false, HORIZONTAL_ALIGNMENT_CENTER, 120)
	Style.text(self, Vector2(chart.position.x, chart.position.y - 14), NAMES[metric] + (" (S)" if metric == "seconds" else ""), 16, Style.TEXT)
	Style.text(self, Vector2(chart.end.x, chart.end.y + 50), "TRAINING STEPS", 16, Style.DIM, false, HORIZONTAL_ALIGNMENT_RIGHT)
	# Average of recent finished training attempts, so the trend shows through the noise.
	var finished := rows.filter(func(row): return row.status in ["died", "timeout"] and row.get("mode") != "evaluation")
	var window := maxi(5, finished.size() / 25)
	var line := PackedVector2Array()
	var total := 0.0
	for i in finished.size():
		total += float(finished[i].get(metric, 0))
		if i >= window:
			total -= float(finished[i - window].get(metric, 0))
		var average := total / mini(i + 1, window)
		var p := _point(finished[i], bounds)
		line.append(Vector2(p.x, chart.end.y - chart.size.y * (average - bounds[2]) / (bounds[3] - bounds[2])))
	if line.size() > 1:
		draw_polyline(line, Style.TEXT, 2.0)
	for row in rows:
		var point := _point(row, bounds)
		if row.get("mode") == "evaluation":
			# Evaluation games (no noise): a diamond, so they stand apart.
			var diamond := PackedVector2Array([point + Vector2(0, -7), point + Vector2(7, 0), point + Vector2(0, 7), point + Vector2(-7, 0)])
			draw_colored_polygon(diamond, PAPER)
			diamond = PackedVector2Array([point + Vector2(0, -5), point + Vector2(5, 0), point + Vector2(0, 5), point + Vector2(-5, 0)])
			draw_colored_polygon(diamond, _color(row))
		elif row.status in ["died", "timeout"]:
			draw_rect(Rect2(point - Vector2(5, 5), Vector2(10, 10)), PAPER)
			draw_rect(Rect2(point - Vector2(4, 4), Vector2(8, 8)), _color(row))
		else:
			draw_rect(Rect2(point - Vector2(4, 4), Vector2(8, 8)), Style.DIM, false, 1.0)
	if current >= 0 and current < rows.size():
		draw_rect(Rect2(_point(rows[current], bounds) - Vector2(8, 8), Vector2(16, 16)), Style.TEXT, false, 1.0)
	_legend(Vector2(chart.end.x, chart.position.y - 20), window)
	if hover >= 0:
		_tooltip(rows[hover], _point(rows[hover], bounds))

func _legend(right_top: Vector2, window: int) -> void:
	var entries := [[Style.BEHIND, "DIED"], [Style.GOLD, "SURVIVED"], [Style.DIM, "CUT SHORT"], [Style.TEXT, "EVAL"], [Style.TEXT, "AVG OF %d" % window]]
	var width := 0.0
	for entry in entries:
		width += Style.width_of(entry[1]) + 40.0
	var x := right_top.x - width
	for entry in entries:
		if entry[1].begins_with("AVG"):
			draw_rect(Rect2(x, right_top.y - 1, 14, 2), entry[0])
		elif entry[1] == "EVAL":
			draw_polyline(PackedVector2Array([Vector2(x + 6, right_top.y - 5), Vector2(x + 11, right_top.y),
				Vector2(x + 6, right_top.y + 5), Vector2(x + 1, right_top.y), Vector2(x + 6, right_top.y - 5)]), entry[0], 1.0)
		else:
			draw_rect(Rect2(x + 2, right_top.y - 4, 8, 8), entry[0], entry[1] != "CUT SHORT", 1.0)
		Style.text(self, Vector2(x + 20, right_top.y + 6), entry[1], 16, Style.DIM)
		x += Style.width_of(entry[1]) + 40.0

func _tooltip(row: Dictionary, point: Vector2) -> void:
	var ending: String = {"died": "DIED", "timeout": "SURVIVED"}.get(row.status, "CUT SHORT")
	if row.get("mode") == "evaluation":
		ending += "  EVAL"
	var detail := "%s  %d KILLS  %d COLLISIONS  %d FELL" % [Style.clock(row.seconds), row.kills,
		row.get("collisions", 0), row.get("fell_off", 0)]
	var box := Rect2(point + Vector2(14, -64), Vector2(Style.width_of(detail) + 28, 58))
	box.position.x = minf(box.position.x, size.x - box.size.x - 10)
	box.position.y = maxf(box.position.y, 10)
	draw_rect(box, Color("1c1c1e"))
	draw_rect(box, Color(Style.TEXT, 0.25), false, 1.0)
	Style.text(self, box.position + Vector2(14, 24), "ATTEMPT %d  %s" % [row.number, ending], 16, _color(row), true)
	Style.text(self, box.position + Vector2(14, 46), detail, 16, Style.TEXT)

func _nearest(point: Vector2) -> int:
	if rows.is_empty():
		return -1
	var bounds := _range()
	var best := -1
	var distance := 10.0
	for i in rows.size():
		var d := point.distance_to(_point(rows[i], bounds))
		if d < distance:
			distance = d
			best = i
	return best

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var found := _nearest(event.position)
		if found != hover:
			hover = found
			queue_redraw()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var toggles := _toggles()
		for key in toggles:
			if toggles[key].has_point(event.position):
				if key == "folder":
					open_folder.emit()
				else:
					set_metric(key)
				return
		var found := _nearest(event.position)
		if found >= 0:
			chosen.emit(found)
