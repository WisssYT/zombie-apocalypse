extends CharacterBody3D
const BULLET_SCENE = preload("res://bullet.tscn")
# Where the weapon pivot sits relative to the first-person camera: close enough for the arms to reach.
const FPS_WEAPON_OFFSET := Vector3(-0.14, -0.48, 0.07)
# Rolls the rifle so its textured side faces the camera instead of its stretched top.
const FPS_WEAPON_CANT := deg_to_rad(-20.0)

var shot_cooldown: float = 0.0
@export var magazine_size: int = 12
@export var reload_duration: float = 1.25
var ammo_in_magazine: int = 12
var reserve_ammo: int = 48
var reload_time_left: float = 0.0
var reloading := false
@export var speed: float = 5.0
@export var shooting_speed_multiplier := 0.65
@export var reload_speed_multiplier := 0.42
@export var dash_speed := 15.0
@export var dash_duration := 0.18
@export var dash_cooldown_duration := 1.5
var dash_time_left := 0.0
var dash_cooldown_left := 0.0
var dash_direction := Vector3.FORWARD
var last_move_direction := Vector3.FORWARD
var shooting_slow_time := 0.0
var gravity: float = 9.8
var health: float = 100.0
var dead := false
var hurt_cooldown := 0.0
var player_material: StandardMaterial3D
var fps_mode := false
var look_yaw := 0.0
var look_pitch := 0.0
@export var mouse_sensitivity: float = 0.0025
@onready var fps_rig: Node3D = $FirstPersonRig
@onready var fps_camera: Camera3D = $FirstPersonRig/FirstPersonCamera
@onready var overhead_camera: Camera3D = get_parent().get_node("Camera3D")
@onready var shoot_sound: AudioStreamPlayer = $ShootSound
@onready var reload_sound: AudioStreamPlayer = $ReloadSound
@onready var empty_sound: AudioStreamPlayer = $EmptySound
@onready var hurt_sound: AudioStreamPlayer = $HurtSound
var crosshair: Label

func _ready() -> void:
	player_material = $MeshInstance3D.material_override.duplicate()
	$MeshInstance3D.material_override = player_material
	var overlay := CanvasLayer.new()
	add_child(overlay)
	crosshair = Label.new()
	crosshair.text = "+"
	crosshair.add_theme_font_size_override("font_size", 24)
	crosshair.add_theme_color_override("font_shadow_color", Color.BLACK)
	crosshair.add_theme_constant_override("shadow_offset_x", 1)
	crosshair.add_theme_constant_override("shadow_offset_y", 1)
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	crosshair.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	crosshair.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	overlay.add_child(crosshair)
	crosshair.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	crosshair.offset_left = -15
	crosshair.offset_right = 15
	crosshair.offset_top = -15
	crosshair.offset_bottom = 15
	crosshair.hide()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_perspective") and not dead:
		set_fps_mode(not fps_mode)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_cancel") and fps_mode:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and fps_mode and not dead:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and fps_mode and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not dead:
		look_yaw -= event.relative.x * mouse_sensitivity
		look_pitch = clampf(look_pitch - event.relative.y * mouse_sensitivity, deg_to_rad(-80), deg_to_rad(80))
		update_fps_pose()

func set_fps_mode(enabled: bool) -> void:
	fps_mode = enabled
	if enabled:
		look_yaw = $WeaponPivot.rotation.y
		look_pitch = 0.0
		update_fps_pose()
		fps_camera.make_current()
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		overhead_camera.make_current()
		$WeaponPivot.position = Vector3.ZERO
		$WeaponPivot.rotation = Vector3(0, look_yaw, 0)
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	crosshair.visible = enabled

func update_fps_pose() -> void:
	fps_rig.rotation = Vector3(look_pitch, look_yaw, 0)
	$WeaponPivot.global_transform = Transform3D(fps_camera.global_basis * Basis(Vector3.BACK, FPS_WEAPON_CANT), fps_camera.global_transform * FPS_WEAPON_OFFSET)

# A future visual-learning adapter can use this camera, not enemy coordinates.
func get_observation_camera() -> Camera3D:
	return fps_camera

func _physics_process(delta: float) -> void:
	if dead:
		return
	hurt_cooldown = maxf(0.0, hurt_cooldown - delta)
	player_material.albedo_color = Color(1, 0.2, 0.15) if hurt_cooldown > 0.25 else Color(0.236, 0.414, 1)
	if global_position.y < -8.0:
		take_damage(100.0)
		return
	if not is_on_floor():
		velocity.y -= gravity * delta
		
	else:
		velocity.y =0.0
	
	var direction := Input.get_vector(
		"move_left", "move_right", "move_up", "move_down"
	)
	var movement := Vector3(direction.x, 0, direction.y)
	if fps_mode:
		movement = movement.rotated(Vector3.UP, look_yaw)
	if movement.length_squared() > 0.01:
		last_move_direction = movement.normalized()
	dash_cooldown_left = maxf(0.0, dash_cooldown_left - delta)
	dash_time_left = maxf(0.0, dash_time_left - delta)
	shooting_slow_time = maxf(0.0, shooting_slow_time - delta)
	if Input.is_action_just_pressed("dash"):
		start_dash(movement)
	if fps_mode:
		update_fps_pose()
	else:
		aim_at_mouse()
		fps_rig.rotation = Vector3(0, $WeaponPivot.rotation.y, 0)
	handle_reload(delta)
	handle_shooting(delta)
	var ground_velocity := movement * get_movement_speed()
	if dash_time_left > 0.0:
		ground_velocity = dash_direction * dash_speed
	velocity.x = ground_velocity.x
	velocity.z = ground_velocity.z
	move_and_slide()

func get_movement_speed() -> float:
	if reloading:
		return speed * reload_speed_multiplier
	if shooting_slow_time > 0.0:
		return speed * shooting_speed_multiplier
	return speed

func start_dash(direction: Vector3) -> void:
	if dead or dash_cooldown_left > 0.0 or dash_time_left > 0.0:
		return
	direction.y = 0.0
	dash_direction = direction.normalized() if direction.length_squared() > 0.01 else last_move_direction
	dash_time_left = dash_duration
	dash_cooldown_left = dash_cooldown_duration
	# A panic dash cancels an unfinished reload; ammunition is preserved.
	if reloading:
		reloading = false
		reload_time_left = 0.0
		reload_sound.stop()
	


func aim_at_mouse() -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return

	var mouse_position := get_viewport().get_mouse_position()
	var ray_start := camera.project_ray_origin(mouse_position)
	var ray_direction := camera.project_ray_normal(mouse_position)

	# An invisible horizontal plane at the weapon pivot's height.
	var aim_plane := Plane(
		Vector3.UP,
		$WeaponPivot.global_position.y
	)

	var hit = aim_plane.intersects_ray(ray_start, ray_direction)

	if hit != null:
		var target: Vector3 = hit
		if $WeaponPivot.global_position.distance_to(target) > 0.01:
			$WeaponPivot.look_at(target, Vector3.UP)
			
func handle_shooting(delta: float) -> void:
	shot_cooldown = maxf(0.0, shot_cooldown - delta)
	if dash_time_left > 0.0:
		return
	if fps_mode and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if Input.is_action_pressed("shoot") and shot_cooldown <= 0.0:
		if reloading:
			return
		if ammo_in_magazine == 0:
			empty_sound.play()
			shot_cooldown = 0.35
			start_reload()
		else:
			shoot()
			shot_cooldown = 0.2

func handle_reload(delta: float) -> void:
	if reloading:
		reload_time_left -= delta
		if reload_time_left <= 0.0:
			finish_reload()
	elif Input.is_action_just_pressed("reload"):
		start_reload()

func start_reload() -> void:
	if dead or reloading or dash_time_left > 0.0 or ammo_in_magazine >= magazine_size or reserve_ammo <= 0:
		return
	reloading = true
	reload_time_left = reload_duration
	reload_sound.play()

func finish_reload() -> void:
	if not reloading:
		return
	var amount := mini(magazine_size - ammo_in_magazine, reserve_ammo)
	ammo_in_magazine += amount
	reserve_ammo -= amount
	reloading = false
	reload_time_left = 0.0

func shoot() -> void:
	if dead or reloading or dash_time_left > 0.0 or ammo_in_magazine <= 0:
		return
	shooting_slow_time = 0.22
	ammo_in_magazine -= 1
	shoot_sound.play()
	var bullet = BULLET_SCENE.instantiate()
	var muzzle = $WeaponPivot/Muzzle

	bullet.add_collision_exception_with(self)
	get_tree().current_scene.add_child(bullet)

	bullet.global_position = muzzle.global_position
	bullet.direction = -muzzle.global_transform.basis.z.normalized()
	if fps_mode:
		var origin := fps_camera.global_position
		var target := origin - fps_camera.global_basis.z * 100.0
		var query := PhysicsRayQueryParameters3D.create(origin, target)
		query.exclude = [get_rid()]
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		if not hit.is_empty():
			target = hit.position
		bullet.direction = (target - muzzle.global_position).normalized()

func take_damage(amount: float) -> void:
	if dead or hurt_cooldown > 0.0:
		return
	health = maxf(0.0, health - amount)
	hurt_cooldown = 0.45
	hurt_sound.play()
	if health <= 0.0:
		dead = true
		velocity = Vector3.ZERO
		player_material.albedo_color = Color(0.25, 0.25, 0.3)
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
