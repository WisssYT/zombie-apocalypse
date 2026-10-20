extends Control
## Input display, NohBoard style: the controls the network sent this decision.
## Movement is analog, so the keys light in proportion and the stick shows the
## exact vector. The arrow on the mouse is how it pushes the mouse; the dial is
## where the gun actually points.

const Style := preload("res://training/replay_style.gd")
const KEY := 34.0
const GAP := 4.0

var action := PackedFloat32Array()
var aim := Vector2.ZERO

func _ready() -> void:
	custom_minimum_size = Vector2(340, 124)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func show_action(value: PackedFloat32Array, gun_aim: Vector2) -> void:
	action = value
	aim = gun_aim
	queue_redraw()

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Style.BG)
	if action.size() != 7:
		return
	var move := Vector2(action[0], action[1]).limit_length(1.0)
	var o := Vector2(10, 10)
	var k := KEY + GAP
	_key(Rect2(o + Vector2(k, 0), Vector2(KEY, KEY)), "Z", -move.y)
	_key(Rect2(o + Vector2(0, k), Vector2(KEY, KEY)), "Q", -move.x)
	_key(Rect2(o + Vector2(k, k), Vector2(KEY, KEY)), "S", move.y)
	_key(Rect2(o + Vector2(k * 2, k), Vector2(KEY, KEY)), "D", move.x)
	_key(Rect2(o + Vector2(0, k * 2), Vector2(KEY * 3 + GAP * 2, 28)), "SPACE", 1.0 if action[6] > 0.0 else 0.0)
	_key(Rect2(o + Vector2(k * 3 + 8, 0), Vector2(KEY, KEY)), "R", 1.0 if action[5] > 0.0 else 0.0)
	# Mouse: left button is fire.
	var mouse := Rect2(o + Vector2(k * 3 + 8, k), Vector2(KEY, KEY + 28 + GAP))
	draw_rect(mouse, Style.ZERO)
	draw_rect(mouse, Color(Style.TEXT, 0.3), false, 1.0)
	if action[4] > 0.0:
		draw_rect(Rect2(mouse.position + Vector2(1, 1), Vector2(KEY * 0.5 - 1, 24)), Style.TEXT)
	draw_line(mouse.position + Vector2(KEY * 0.5, 0), mouse.position + Vector2(KEY * 0.5, 25), Color(Style.TEXT, 0.3))
	draw_line(mouse.position + Vector2(0, 25), mouse.position + Vector2(KEY, 25), Color(Style.TEXT, 0.3))
	var push := Vector2(action[2], action[3]).limit_length(1.0)
	var middle := mouse.position + Vector2(KEY * 0.5, 44)
	if push.length() > 0.05:
		draw_line(middle, middle + push * 14.0, Style.ON, 2.0)
		draw_rect(Rect2(middle + push * 14.0 - Vector2(2, 2), Vector2(4, 4)), Style.ON)
	_ring(Vector2(232, 62), 42, move, false)
	_ring(Vector2(304, 62), 26, aim, true)

func _key(rect: Rect2, label: String, amount: float) -> void:
	amount = clampf(amount, 0.0, 1.0)
	draw_rect(rect, Style.ZERO.lerp(Style.TEXT, amount))
	draw_rect(rect, Color(Style.TEXT, 0.3), false, 1.0)
	var color := Color("111111") if amount > 0.5 else Style.TEXT
	Style.text(self, Vector2(rect.position.x, rect.get_center().y + 6), label, 16, color, true,
		HORIZONTAL_ALIGNMENT_CENTER, rect.size.x)

func _ring(center: Vector2, radius: float, vector: Vector2, direction_only: bool) -> void:
	draw_arc(center, radius, 0, TAU, 40, Color(Style.TEXT, 0.3), 1.0)
	draw_line(center - Vector2(radius, 0), center + Vector2(radius, 0), Color(Style.TEXT, 0.08))
	draw_line(center - Vector2(0, radius), center + Vector2(0, radius), Color(Style.TEXT, 0.08))
	if direction_only:
		if vector.length_squared() > 0.000001:
			draw_line(center, center + vector.normalized() * radius, Style.TEXT, 2.0)
		return
	draw_line(center, center + vector * radius, Color(Style.TEXT, 0.6), 1.0)
	draw_rect(Rect2(center + vector * radius - Vector2(4, 4), Vector2(8, 8)), Style.TEXT)
