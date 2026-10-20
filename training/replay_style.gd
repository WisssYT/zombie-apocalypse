extends RefCounted
## Shared look for the replay overlay: one pixel font, speedrun timer colours.

const BG := Color(0.03, 0.03, 0.035, 0.86)
const LINE := Color(1, 1, 1, 0.09)
const TEXT := Color("e8e6df")
const DIM := Color("7d7b74")
const AHEAD := Color("3ddc6f")
const BEHIND := Color("ee4b4b")
const GOLD := Color("f2c14e")
const ON := Color("ffd166")
const OFF := Color("4cc9f0")
const ZERO := Color("1c1c1e")

static var _regular: FontFile
static var _bold: FontFile

static func font(bold := false) -> FontFile:
	if _regular == null:
		_regular = _crisp(load("res://fonts/silkscreen/Silkscreen-Regular.ttf"))
		_bold = _crisp(load("res://fonts/silkscreen/Silkscreen-Bold.ttf"))
	return _bold if bold else _regular

static func _crisp(source: FontFile) -> FontFile:
	source.antialiasing = TextServer.FONT_ANTIALIASING_NONE
	source.hinting = TextServer.HINTING_NONE
	source.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	return source

## Signed activation (-1..1) to an LED colour: dark at zero, warm up, cold down.
static func led(v: float) -> Color:
	return ZERO.lerp(ON if v > 0.0 else OFF, pow(clampf(absf(v), 0.0, 1.0), 0.7))

## Silkscreen is drawn on an 8px grid; 16 is the normal size, 32/48 for big numbers.
static func text(item: CanvasItem, at: Vector2, value: String, size := 16, color := TEXT,
		bold := false, align := HORIZONTAL_ALIGNMENT_LEFT, width := -1.0) -> void:
	if align == HORIZONTAL_ALIGNMENT_RIGHT and width <= 0.0:
		# Right edge at `at.x`, without needing a box width.
		at.x -= width_of(value, size, bold)
		align = HORIZONTAL_ALIGNMENT_LEFT
		width = -1.0
	item.draw_string(font(bold), at.round(), value, align, width, size, color)

static func width_of(value: String, size := 16, bold := false) -> float:
	return font(bold).get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x

static func clock(seconds: float, tenths := true) -> String:
	var minutes := int(seconds) / 60
	return "%d:%04.1f" % [minutes, fmod(seconds, 60.0)] if tenths else "%d:%02d" % [minutes, int(seconds) % 60]

static func steps(value: float) -> String:
	if value >= 1_000_000:
		return "%.1fM" % (value / 1_000_000)
	if value >= 1000:
		return "%dK" % int(value / 1000)
	return str(int(value))
