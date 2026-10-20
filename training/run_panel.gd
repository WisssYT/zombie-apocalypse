extends Control
## Speedrun-style run info: attempt number, run timer and kill splits compared
## with the best attempt recorded so far (most kills).

const Style := preload("res://training/replay_style.gd")
const ROWS := 4
const ROW := 22.0
const SPLITS_TOP := 112.0

var attempt := 0
var attempts := 0
var trained := -1
var note := ""
var status := ""
var end_time := 0.0
var now := 0.0
var kills: Array = []      # this attempt: time of each kill
var best: Array = []       # best attempt: time of each kill
var best_attempt := 0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(200, SPLITS_TOP + ROWS * ROW + 34)

func _draw() -> void:
	var w := size.x
	var right := w - 14.0
	draw_rect(Rect2(Vector2.ZERO, size), Style.BG)
	Style.text(self, Vector2(14, 28), "ATTEMPT %d" % attempt, 16, Style.TEXT, true)
	Style.text(self, Vector2(right, 28), "OF %d" % attempts, 16, Style.DIM, false, HORIZONTAL_ALIGNMENT_RIGHT)
	var detail := "UNTRAINED" if trained <= 0 else "%s STEPS" % Style.steps(trained)
	Style.text(self, Vector2(14, 50), detail, 16, Style.DIM)
	if note != "":
		Style.text(self, Vector2(right, 50), note, 16, Style.DIM, false, HORIZONTAL_ALIGNMENT_RIGHT)
	var finished := now >= end_time - 0.001
	var color := Style.AHEAD
	if finished:
		color = Style.BEHIND if status == "died" else Style.GOLD if status == "timeout" else Style.DIM
	Style.text(self, Vector2(right, 98), Style.clock(now), 48, color, true, HORIZONTAL_ALIGNMENT_RIGHT)
	draw_line(Vector2(0, SPLITS_TOP - 4), Vector2(w, SPLITS_TOP - 4), Style.LINE)
	var count := maxi(kills.size(), best.size())
	var done := 0
	for t in kills:
		if t <= now:
			done += 1
	# Scroll so the next split stays in view, like a split timer does.
	var first := clampi(done - ROWS + 2, 0, maxi(0, count - ROWS))
	for row in ROWS:
		var k := first + row
		var top := SPLITS_TOP + row * ROW
		if row % 2 == 1 and k < count:
			draw_rect(Rect2(0, top - 2, w, ROW), Color(1, 1, 1, 0.03))
		if k >= count:
			if count == 0 and row == 0:
				Style.text(self, Vector2(14, top + 15), "NO KILLS", 16, Style.DIM)
			continue
		var line_y := top + 15
		var reached: bool = k < kills.size() and kills[k] <= now
		Style.text(self, Vector2(14, line_y), "KILL %d" % (k + 1), 16, Style.TEXT if reached else Style.DIM)
		if reached:
			Style.text(self, Vector2(right, line_y), Style.clock(kills[k]), 16, Style.TEXT, false, HORIZONTAL_ALIGNMENT_RIGHT)
			if k < best.size() and best_attempt != attempt:
				var delta: float = kills[k] - best[k]
				Style.text(self, Vector2(right - 92, line_y), "%+.1f" % delta, 16,
					Style.AHEAD if delta < 0.0 else Style.BEHIND, false, HORIZONTAL_ALIGNMENT_RIGHT)
		else:
			Style.text(self, Vector2(right, line_y), Style.clock(best[k]) if k < best.size() else "-", 16,
				Style.DIM, false, HORIZONTAL_ALIGNMENT_RIGHT)
	var footer := SPLITS_TOP + ROWS * ROW
	draw_line(Vector2(0, footer + 2), Vector2(w, footer + 2), Style.LINE)
	if best_attempt > 0:
		Style.text(self, Vector2(14, footer + 24), "BEST", 16, Style.DIM)
		Style.text(self, Vector2(right, footer + 24), "%d KILLS  ATTEMPT %d" % [best.size(), best_attempt], 16,
			Style.GOLD, false, HORIZONTAL_ALIGNMENT_RIGHT)
