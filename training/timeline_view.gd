extends Control
## Bottom bar: previous / play / next attempt, speed, the attempt's track (health
## and kills, click or drag to seek) and the button for the attempts screen.

signal seek(frame: float)
signal pressed(control: String)  # previous, play, next, speed, video, attempts

const Style := preload("res://training/replay_style.gd")
const BUTTON := 34.0

var frames: Array = []
var head := 0.0
var playing := true
var speed := "1X"
var hover := -1.0
var message := ""

func _ready() -> void:
	custom_minimum_size = Vector2(300, 34)
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_exited.connect(func():
		hover = -1.0
		queue_redraw())

func set_episode(episode_frames: Array) -> void:
	frames = episode_frames
	head = 0.0
	queue_redraw()

func _regions() -> Dictionary:
	return {"previous": Rect2(4, 0, BUTTON, size.y), "play": Rect2(4 + BUTTON, 0, BUTTON, size.y),
		"next": Rect2(4 + BUTTON * 2, 0, BUTTON, size.y), "speed": Rect2(4 + BUTTON * 3, 0, 56, size.y),
		"video": Rect2(size.x - 288, 0, 156, size.y), "attempts": Rect2(size.x - 128, 0, 124, size.y)}

func _track() -> Rect2:
	return Rect2(BUTTON * 3 + 72, 11, size.x - BUTTON * 3 - 72 - 304, size.y - 22)

func _x(frame: float) -> float:
	var track := _track()
	return track.position.x + track.size.x * frame / maxf(1.0, frames.size() - 1)

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Style.BG)
	var middle := size.y * 0.5
	var r := _regions()
	var c: Vector2 = r.previous.get_center()
	draw_rect(Rect2(c.x - 6, middle - 5, 2, 10), Style.TEXT)
	draw_colored_polygon(PackedVector2Array([Vector2(c.x + 5, middle - 5), Vector2(c.x + 5, middle + 5), Vector2(c.x - 3, middle)]), Style.TEXT)
	c = r.play.get_center()
	if playing:
		draw_rect(Rect2(c.x - 5, middle - 6, 3, 12), Style.TEXT)
		draw_rect(Rect2(c.x + 2, middle - 6, 3, 12), Style.TEXT)
	else:
		draw_colored_polygon(PackedVector2Array([Vector2(c.x - 4, middle - 6), Vector2(c.x - 4, middle + 6), Vector2(c.x + 6, middle)]), Style.TEXT)
	c = r.next.get_center()
	draw_colored_polygon(PackedVector2Array([Vector2(c.x - 5, middle - 5), Vector2(c.x - 5, middle + 5), Vector2(c.x + 3, middle)]), Style.TEXT)
	draw_rect(Rect2(c.x + 4, middle - 5, 2, 10), Style.TEXT)
	Style.text(self, Vector2(r.speed.position.x, middle + 6), speed, 16, Style.TEXT, true, HORIZONTAL_ALIGNMENT_CENTER, r.speed.size.x)
	Style.text(self, Vector2(r.video.position.x, middle + 6), "SAVE VIDEO", 16, Style.TEXT, true, HORIZONTAL_ALIGNMENT_CENTER, r.video.size.x)
	Style.text(self, Vector2(r.attempts.position.x, middle + 6), "ATTEMPTS", 16, Style.TEXT, true, HORIZONTAL_ALIGNMENT_CENTER, r.attempts.size.x)
	if frames.is_empty():
		return
	var track := _track()
	draw_rect(track, Style.ZERO)
	var last := frames.size() - 1
	draw_rect(Rect2(track.position, Vector2(_x(head) - track.position.x, track.size.y)), Color(Style.TEXT, 0.12))
	# Gold: a kill. Red: a hit taken. Green: a hound charge dodged.
	# White: zombies collided. Cyan: one fell off.
	for i in range(1, frames.size()):
		var now: Dictionary = frames[i].get("stats", {})
		var before: Dictionary = frames[i - 1].get("stats", {})
		if now.get("collision", 0) + now.get("hound_knockdown", 0) > before.get("collision", 0) + before.get("hound_knockdown", 0):
			draw_rect(Rect2(_x(i) - 1, track.position.y, 2, track.size.y * 0.5), Style.TEXT)
		if now.get("charge_dodged", 0) > before.get("charge_dodged", 0):
			draw_rect(Rect2(_x(i) - 1, track.position.y - 3, 2, track.size.y + 6), Style.AHEAD)
		if now.get("fell_off", 0) > before.get("fell_off", 0):
			draw_rect(Rect2(_x(i) - 1, track.position.y - 3, 2, track.size.y + 6), Style.OFF)
		if frames[i].health < frames[i - 1].health:
			draw_rect(Rect2(_x(i) - 1, track.position.y + track.size.y * 0.5, 2, track.size.y * 0.5), Style.BEHIND)
		if frames[i].kills > frames[i - 1].kills:
			draw_rect(Rect2(_x(i) - 1, track.position.y - 3, 2, track.size.y + 6), Style.GOLD)
	draw_rect(Rect2(_x(head) - 1, track.position.y - 4, 2, track.size.y + 8), Style.TEXT)
	if message != "":
		var width := Style.width_of(message)
		draw_rect(Rect2(track.end.x - width - 10, track.position.y - 1, width + 10, track.size.y + 2), Color("050505"))
		Style.text(self, Vector2(track.end.x - 4, track.end.y - 1), message, 16, Style.GOLD, false, HORIZONTAL_ALIGNMENT_RIGHT)
	if hover >= 0.0:
		var i := clampi(int(round(hover)), 0, last)
		var label := Style.clock(frames[i].time)
		var x := clampf(_x(hover) + 6, track.position.x, track.end.x - Style.width_of(label))
		draw_rect(Rect2(x - 3, track.position.y - 1, Style.width_of(label) + 6, track.size.y + 2), Color("050505"))
		Style.text(self, Vector2(x, track.end.y - 1), label, 16, Style.TEXT)

func _frame_at(x: float) -> float:
	var track := _track()
	return clampf((x - track.position.x) / track.size.x, 0.0, 1.0) * (frames.size() - 1)

func _gui_input(event: InputEvent) -> void:
	var on_track := not frames.is_empty() and _track().grow_individual(0, 9, 0, 9).has_point(event.position) \
		if event is InputEventMouse else false
	if event is InputEventMouseMotion:
		hover = _frame_at(event.position.x) if on_track else -1.0
		if on_track and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
			seek.emit(round(hover))
		queue_redraw()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if on_track:
			seek.emit(round(_frame_at(event.position.x)))
			return
		var regions := _regions()
		for name in regions:
			if regions[name].has_point(event.position):
				pressed.emit(name)
				return
