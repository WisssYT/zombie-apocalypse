extends Node3D

const ZOMBIE = preload("res://zombie.tscn")
const HOUND = preload("res://hound.tscn")
const RUSH_SPEED := 5.0
# The building under the arena hides anything behind it from the overhead camera.
const BUILDING := AABB(Vector3(-16.0, -200.0, -10.0), Vector3(32.0, 199.1, 20.0))
var spawn_number := 0
var spawn_countdown := 1.0
var elapsed := 0.0
var kills := 0
var rng := RandomNumberGenerator.new()
var hud: Label
var health_bar: ProgressBar
@onready var player = $"Player _ CharacterBody3D"
@onready var camera: Camera3D = $Camera3D

func _ready() -> void:
	rng.randomize()
	var canvas := CanvasLayer.new()
	add_child(canvas)
	var panel := PanelContainer.new()
	panel.position = Vector2(18, 18)
	panel.custom_minimum_size = Vector2(320, 100)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(panel)
	var column := VBoxContainer.new()
	panel.add_child(column)
	hud = Label.new()
	hud.add_theme_font_size_override("font_size", 19)
	column.add_child(hud)
	health_bar = ProgressBar.new()
	health_bar.max_value = 100.0
	health_bar.custom_minimum_size = Vector2(300, 18)
	column.add_child(health_bar)

func _physics_process(delta: float) -> void:
	if player.dead:
		hud.text = "YOU DIED | Kills: %d\nPress Enter to restart" % kills
		if Input.is_action_just_pressed("restart"):
			get_tree().reload_current_scene()
	else:
		elapsed += delta
		spawn_countdown -= delta
		if spawn_countdown <= 0.0:
			if get_tree().get_nodes_in_group("zombies").size() < 18:
				spawn_zombie()
			spawn_countdown = maxf(1.4, 3.5 - elapsed / 90.0)
		var ammo_text := "RELOADING..." if player.reloading else "AMMO %d / %d" % [player.ammo_in_magazine, player.reserve_ammo]
		var dash_text := "READY" if player.dash_cooldown_left <= 0.0 else "%.1fs" % player.dash_cooldown_left
		hud.text = "HEALTH %d / 100 | Kills: %d\n%s | R: reload\nDASH %s | Space: dodge\nSurvived: %ds | C: change view\nZQSD + mouse | Esc: release cursor" % [int(player.health), kills, ammo_text, dash_text, int(elapsed)]
	health_bar.value = player.health

func spawn_zombie() -> Node3D:
	# Each wall has the same chance, regardless of the active camera or visibility.
	var outward: Vector3
	var edge: Vector3
	match rng.randi_range(0, 3):
		0:
			outward = Vector3(0, 0, 1)
			edge = Vector3(rng.randf_range(-14.5, 14.5), -0.5, 10.0)
		1:
			outward = Vector3(0, 0, -1)
			edge = Vector3(rng.randf_range(-14.5, 14.5), -0.5, -10.0)
		2:
			outward = Vector3(1, 0, 0)
			edge = Vector3(16.0, -0.5, rng.randf_range(-8.5, 8.5))
		_:
			outward = Vector3(-1, 0, 0)
			edge = Vector3(-16.0, -0.5, rng.randf_range(-8.5, 8.5))
	var reveal := edge + outward * 0.46 + Vector3.DOWN * rng.randf_range(8.0, 12.0)
	# Start below the overhead view, then scramble up to the usual climbing height.
	var start := reveal
	while start.y > -45.0 and not hidden_from_overhead(start, outward):
		start += Vector3.DOWN
	start += Vector3.DOWN * 1.5
	var top := edge + outward * 0.55 + Vector3.UP * 1.05
	var land := edge - outward * 0.8 + Vector3.UP * 1.05
	spawn_number += 1
	# Introduce one hound after the first three runners, then keep a mixed horde.
	var use_hound := spawn_number % 4 == 0
	var zombie = (HOUND if use_hound else ZOMBIE).instantiate()
	zombie.player = player
	zombie.climb_start = start
	zombie.climb_reveal = reveal
	zombie.climb_top = top
	zombie.landing = land
	zombie.rush_duration = start.distance_to(reveal) / RUSH_SPEED
	zombie.climb_duration = reveal.distance_to(top) / 1.25
	zombie.speed = rng.randf_range(7.8, 8.4) if use_hound else rng.randf_range(6.1, 6.6)
	# Place it before adding: added at the origin first, it would shove the player there.
	zombie.transform = Transform3D(Basis.looking_at(-outward, Vector3.UP), start)
	add_child(zombie)
	return zombie

func hidden_from_overhead(center: Vector3, outward: Vector3) -> bool:
	# Uses the overhead camera even in first person, so spawns behave the same in both views.
	var to_camera := camera.global_basis.z
	for point in [center + Vector3.UP * 1.0, center + Vector3.DOWN * 1.0, center + outward * 0.4]:
		if camera.is_position_in_frustum(point) and BUILDING.intersects_segment(point, point + to_camera * 300.0) == null:
			return false
	return true

func register_kill() -> void:
	kills += 1


