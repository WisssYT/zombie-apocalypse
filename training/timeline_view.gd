extends Control
## Episode scrubber: health over the round, the value network's running estimate
## of how well things are going, and a mark for every kill. Click or drag to seek.

signal seek(frame: float)

const INK := Color("f0efec")
const INK_2 := Color("c3c2b7")
const MUTED := Color("8c8b84")
const HEALTH := Color("d95926")
const VALUE := Color("3987e5")

var frames: Array = []
var values := PackedFloat32Array()
var head := 0.0
var hover := -1.0
var font: Font

func _ready() -> void:
	font = get_theme_default_font()
	custom_minimum_size = Vector2(200, 54)
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_exited.connect(func():
		hover = -1.0
		queue_redraw())

func set_episode(episode_frames: Array, episode_values: PackedFloat32Array) -> void:
	frames = episode_frames
	values = episode_values
	head = 0.0
	queue_redraw()

func _track() -> Rect2:
	return Rect2(4, 16, size.x - 8, size.y - 22)

func _x(frame: float) -> float:
	var track := _track()
	return track.position.x + track.size.x * frame / maxf(1.0, frames.size() - 1)

func _draw() -> void:
	if frames.is_empty():
		return
	var track := _track()
	draw_rect(track, Color(INK, 0.04))
	var last := frames.size() - 1
	var health := PackedVector2Array([Vector2(track.position.x, track.end.y)])
	for i in frames.size():
		health.append(Vector2(_x(i), track.end.y - track.size.y * clampf(frames[i].health / 100.0, 0.0, 1.0)))
	health.append(Vector2(_x(last), track.end.y))
	draw_colored_polygon(health, Color(HEALTH, 0.16))
	draw_polyline(health.slice(1, health.size() - 1), Color(HEALTH, 0.7), 1.5, true)
	if values.size() > 1:
		var low := values[0]
		var high := values[0]
		for v in values:
			low = minf(low, v)
			high = maxf(high, v)
		var span := maxf(high - low, 0.001)
		var line := PackedVector2Array()
		for i in values.size():
			line.append(Vector2(_x(i), track.end.y - 3.0 - (track.size.y - 6.0) * (values[i] - low) / span))
		draw_polyline(line, VALUE, 2.0, true)
	for i in range(1, frames.size()):
		if frames[i].kills > frames[i - 1].kills:
			var x := _x(i)
			draw_line(Vector2(x, track.position.y), Vector2(x, track.end.y), Color(INK, 0.5), 1.0)
			draw_circle(Vector2(x, track.position.y), 3.0, INK)
	var x_head := _x(head)
	draw_line(Vector2(x_head, track.position.y - 4), Vector2(x_head, track.end.y + 2), INK, 2.0)
	_legend(track)
	if hover >= 0.0:
		var i := clampi(int(round(hover)), 0, last)
		var text := "%s   health %d" % [clock(frames[i].time), int(frames[i].health)]
		if i < values.size():
			text += "   value %+.2f" % values[i]
		var x := clampf(_x(hover) - 70.0, 0.0, size.x - 200.0)
		draw_string(font, Vector2(x, 11), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, INK)

func _legend(track: Rect2) -> void:
	var x := track.end.x - 300.0
	draw_rect(Rect2(x, 4, 14, 8), Color(HEALTH, 0.5))
	draw_string(font, Vector2(x + 20, 12), "health", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, INK_2)
	draw_line(Vector2(x + 76, 8), Vector2(x + 90, 8), VALUE, 2.0)
	draw_string(font, Vector2(x + 96, 12), "value estimate", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, INK_2)
	draw_circle(Vector2(x + 202, 8), 3.0, INK)
	draw_string(font, Vector2(x + 210, 12), "kill", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, INK_2)

static func clock(seconds: float) -> String:
	return "%d:%04.1f" % [int(seconds) / 60, fmod(seconds, 60.0)]

func _frame_at(x: float) -> float:
	var track := _track()
	return clampf((x - track.position.x) / track.size.x, 0.0, 1.0) * (frames.size() - 1)

func _gui_input(event: InputEvent) -> void:
	if frames.is_empty():
		return
	if event is InputEventMouseMotion:
		hover = _frame_at(event.position.x)
		if event.button_mask & MOUSE_BUTTON_MASK_LEFT:
			seek.emit(round(hover))
		queue_redraw()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		seek.emit(round(_frame_at(event.position.x)))
