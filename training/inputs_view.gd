extends Control
## What the network sent to the game this decision, drawn as the controls a
## person would use: ZQSD, Space, R, the mouse button, and where it aims.

const INK := Color("f0efec")
const MUTED := Color("8c8b84")
const KEY := 30.0
const GAP := 4.0

var action := PackedFloat32Array()
var font: Font

func _ready() -> void:
	font = get_theme_default_font()
	custom_minimum_size = Vector2(318, 124)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func show_action(value: PackedFloat32Array) -> void:
	action = value
	queue_redraw()

func _draw() -> void:
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color(0.06, 0.06, 0.06, 0.62)
	panel.set_corner_radius_all(6)
	draw_style_box(panel, Rect2(Vector2.ZERO, size))
	if action.size() != 7:
		return
	var move := Vector2(action[0], action[1]).limit_length(1.0)
	var origin := Vector2(12, 12)
	_key(Rect2(origin + Vector2(KEY + GAP, 0), Vector2(KEY, KEY)), "Z", maxf(0.0, -move.y))
	_key(Rect2(origin + Vector2(0, KEY + GAP), Vector2(KEY, KEY)), "Q", maxf(0.0, -move.x))
	_key(Rect2(origin + Vector2(KEY + GAP, KEY + GAP), Vector2(KEY, KEY)), "S", maxf(0.0, move.y))
	_key(Rect2(origin + Vector2((KEY + GAP) * 2, KEY + GAP), Vector2(KEY, KEY)), "D", maxf(0.0, move.x))
	_key(Rect2(origin + Vector2(0, (KEY + GAP) * 2 + 4), Vector2(KEY * 3 + GAP * 2, 24)), "Space", 1.0 if action[6] > 0.0 else 0.0)
	# Analog stick: the exact movement vector, which the keys only approximate.
	var stick := Vector2(152, 50)
	draw_arc(stick, 28, 0, TAU, 40, Color(INK, 0.25), 1.5, true)
	draw_line(stick, stick + move * 28, Color(INK, 0.7), 2.0, true)
	draw_circle(stick, 5, Color(INK, 0.35 + 0.6 * move.length()))
	draw_circle(stick + move * 28, 4, INK)
	_label(Vector2(152, 96), "move")
	# Mouse: left button is shooting; the dial is the aim direction it asked for.
	var mouse := Rect2(198, 14, 36, 54)
	var body := StyleBoxFlat.new()
	body.bg_color = Color(INK, 0.08)
	body.border_color = Color(INK, 0.35)
	body.set_border_width_all(1)
	body.set_corner_radius_all(16)
	draw_style_box(body, mouse)
	if action[4] > 0.0:
		var button := StyleBoxFlat.new()
		button.bg_color = INK
		button.corner_radius_top_left = 16
		draw_style_box(button, Rect2(mouse.position, Vector2(mouse.size.x * 0.5, 22)))
	draw_line(mouse.position + Vector2(mouse.size.x * 0.5, 0), mouse.position + Vector2(mouse.size.x * 0.5, 22), Color(INK, 0.35))
	draw_line(mouse.position + Vector2(0, 22), mouse.position + Vector2(mouse.size.x, 22), Color(INK, 0.35))
	_label(Vector2(216, 96), "fire")
	_key(Rect2(248, 14, KEY, KEY), "R", 1.0 if action[5] > 0.0 else 0.0)
	var dial := Vector2(263, 72)
	var aim := Vector2(action[2], action[3])
	draw_arc(dial, 14, 0, TAU, 32, Color(INK, 0.25), 1.5, true)
	if aim.length_squared() > 0.000001:
		draw_line(dial, dial + aim.normalized() * 14, INK, 2.0, true)
	_label(Vector2(263, 104), "aim")

func _key(rect: Rect2, text: String, amount: float) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(INK, 0.08).lerp(INK, clampf(amount, 0.0, 1.0) * 0.9)
	style.border_color = Color(INK, 0.35)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	draw_style_box(style, rect)
	var color := Color("111111") if amount > 0.5 else INK
	draw_string(font, Vector2(rect.position.x, rect.get_center().y + 5), text,
		HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, 14, color)

func _label(center: Vector2, text: String) -> void:
	draw_string(font, center - Vector2(30, 0), text, HORIZONTAL_ALIGNMENT_CENTER, 60, 11, MUTED)
