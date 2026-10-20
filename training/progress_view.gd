extends Control
## Every recorded episode across all training sessions, in training order.
## Click a dot to watch that game.

signal chosen(index: int)
signal open_folder

const INK := Color("f0efec")
const INK_2 := Color("c3c2b7")
const MUTED := Color("8c8b84")
const DIED := Color("d95926")
const SURVIVED := Color("3987e5")
const METRICS := {"seconds": "Survival time (s)", "kills": "Kills", "reward": "Reward"}

var rows: Array = []
var current := -1
var metric := "seconds"
var source := ""
var message := ""
var hover := -1
var font: Font
var buttons := {}

func _ready() -> void:
	font = get_theme_default_font()
	mouse_filter = Control.MOUSE_FILTER_STOP
	var bar := HBoxContainer.new()
	bar.position = Vector2(28, 64)
	add_child(bar)
	for key in METRICS:
		var button := Button.new()
		button.text = METRICS[key].trim_suffix(" (s)")
		button.toggle_mode = true
		button.button_pressed = key == metric
		button.pressed.connect(func(): set_metric(key))
		bar.add_child(button)
		buttons[key] = button
	var folder := Button.new()
	folder.text = "Open folder…"
	folder.pressed.connect(func(): open_folder.emit())
	bar.add_child(folder)
	resized.connect(queue_redraw)

func set_metric(key: String) -> void:
	metric = key
	for other in buttons:
		buttons[other].set_pressed_no_signal(other == key)
	queue_redraw()

func _chart() -> Rect2:
	return Rect2(80, 120, size.x - 120, size.y - 190)

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
		top = maxf(top, float(row[metric]))
		bottom = minf(bottom, float(row[metric]))
	if high <= low:
		high = low + 1.0
	# Round tick steps (1, 2 or 5 x 10^n) so the axis reads 0, 5, 10, 15...
	top *= 1.1  # headroom under the legend
	var raw := maxf(top - bottom, 1.0) / 4.0
	var magnitude := pow(10.0, floorf(log(raw) / log(10.0)))
	var tick := magnitude * (1.0 if raw <= magnitude else 2.0 if raw <= 2.0 * magnitude else 5.0 if raw <= 5.0 * magnitude else 10.0)
	return [low, high, floorf(bottom / tick) * tick, ceilf(top / tick) * tick, tick]

func _point(row: Dictionary, bounds: Array) -> Vector2:
	var chart := _chart()
	return Vector2(chart.position.x + chart.size.x * (_x_value(row) - bounds[0]) / (bounds[1] - bounds[0]),
		chart.end.y - chart.size.y * (float(row[metric]) - bounds[2]) / (bounds[3] - bounds[2]))

static func steps(value: float) -> String:
	if value >= 1_000_000:
		return "%.1fM" % (value / 1_000_000)
	if value >= 1000:
		return "%dk" % int(value / 1000)
	return str(int(value))

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("1a1a19"))
	draw_string(font, Vector2(28, 40), "Training progress", HORIZONTAL_ALIGNMENT_LEFT, -1, 22, INK)
	var summary := message
	if rows.size() > 0:
		summary = "%d games recorded, %s training steps   ·   %s" % [rows.size(), steps(_x_value(rows.back())), source.trim_suffix("/").get_file()]
	draw_string(font, Vector2(260, 40), summary, HORIZONTAL_ALIGNMENT_LEFT, size.x - 290, 13, MUTED)
	draw_string(font, Vector2(28, size.y - 24), "Click a game to watch it.   Tab closes this screen.   Page Up / Page Down step through games.",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, MUTED)
	if rows.is_empty():
		return
	var chart := _chart()
	var bounds := _range()
	var ticks := roundi((bounds[3] - bounds[2]) / bounds[4])
	for k in ticks + 1:
		var value: float = bounds[2] + bounds[4] * k
		var y := chart.end.y - chart.size.y * k / float(ticks)
		draw_line(Vector2(chart.position.x, y), Vector2(chart.end.x, y), Color(INK, 0.2 if is_zero_approx(value) else 0.06))
		draw_string(font, Vector2(chart.position.x - 60, y + 4), "%.0f" % value if bounds[4] >= 1.0 else "%.1f" % value,
			HORIZONTAL_ALIGNMENT_RIGHT, 50, 12, MUTED)
	for k in 5:
		var x := chart.position.x + chart.size.x * k / 4.0
		draw_string(font, Vector2(x - 40, chart.end.y + 20), steps(bounds[0] + (bounds[1] - bounds[0]) * k / 4.0),
			HORIZONTAL_ALIGNMENT_CENTER, 80, 12, MUTED)
	draw_string(font, Vector2(chart.position.x, chart.position.y - 10), METRICS[metric], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, INK_2)
	draw_string(font, Vector2(chart.end.x - 200, chart.end.y + 38), "training steps", HORIZONTAL_ALIGNMENT_RIGHT, 200, 12, MUTED)
	# Rolling average of finished games, so the trend shows through noisy single games.
	var finished := rows.filter(func(row): return row.status in ["died", "timeout"])
	var window := maxi(5, finished.size() / 25)
	var line := PackedVector2Array()
	var total := 0.0
	for i in finished.size():
		total += float(finished[i][metric])
		if i >= window:
			total -= float(finished[i - window][metric])
		var average := total / mini(i + 1, window)
		var p := _point(finished[i], bounds)
		line.append(Vector2(p.x, chart.end.y - chart.size.y * (average - bounds[2]) / (bounds[3] - bounds[2])))
	if line.size() > 1:
		draw_polyline(line, INK, 2.0, true)
	var ring := Color("1a1a19")
	for i in rows.size():
		var row: Dictionary = rows[i]
		var point := _point(row, bounds)
		if row.status == "died":
			draw_circle(point, 6.0, ring)
			draw_circle(point, 4.0, DIED)
		elif row.status == "timeout":
			draw_circle(point, 6.0, ring)
			draw_circle(point, 4.0, SURVIVED)
		else:
			draw_arc(point, 3.5, 0, TAU, 16, MUTED, 1.5)
	if current >= 0 and current < rows.size():
		draw_arc(_point(rows[current], bounds), 8.0, 0, TAU, 24, INK, 1.5)
	var legend := Vector2(chart.end.x - 520, chart.position.y - 14)
	draw_circle(legend, 4.0, DIED)
	draw_string(font, legend + Vector2(10, 4), "died", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, INK_2)
	draw_circle(legend + Vector2(60, 0), 4.0, SURVIVED)
	draw_string(font, legend + Vector2(70, 4), "lasted the full round", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, INK_2)
	draw_line(legend + Vector2(222, 0), legend + Vector2(240, 0), INK, 2.0)
	draw_string(font, legend + Vector2(246, 4), "average of last %d finished" % window, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, INK_2)
	draw_arc(legend + Vector2(424, 0), 3.5, 0, TAU, 16, MUTED, 1.5)
	draw_string(font, legend + Vector2(434, 4), "cut short", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, INK_2)
	if hover >= 0:
		var row: Dictionary = rows[hover]
		var point := _point(row, bounds)
		var ending: String = {"died": "died", "timeout": "lasted the full round"}.get(row.status, "cut short")
		var lines := ["Game %d" % row.number, "%.1f s, %d kills, %s" % [row.seconds, row.kills, ending],
			"after %s training steps" % steps(_x_value(row))]
		var box := Rect2(point + Vector2(12, -64), Vector2(230, 62))
		box.position.x = minf(box.position.x, size.x - box.size.x - 10)
		box.position.y = maxf(box.position.y, 10)
		var style := StyleBoxFlat.new()
		style.bg_color = Color("262624")
		style.set_corner_radius_all(4)
		draw_style_box(style, box)
		for k in lines.size():
			draw_string(font, box.position + Vector2(10, 20 + k * 17), lines[k], HORIZONTAL_ALIGNMENT_LEFT, -1, 13 if k == 0 else 12, INK if k == 0 else INK_2)

func _nearest(point: Vector2) -> int:
	if rows.is_empty():
		return -1
	var bounds := _range()
	var best := -1
	var distance := 12.0
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
		var found := _nearest(event.position)
		if found >= 0:
			chosen.emit(found)
