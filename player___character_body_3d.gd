extends CharacterBody3D
const BULLET_SCENE = preload("res://bullet.tscn")

# Observation schema v3: 32 player values + 18 slots of 31 enemy values.
const MAX_OBSERVED_ENEMIES := 18
const PLAYER_OBSERVATION_FIELDS := [
	"health",
	"magazine_ammo",
	"reserve_ammo",
	"reloading",
	"dash_cooldown",
	"position_x",
	"position_y",
	"position_z",
	"velocity_x",
	"velocity_y",
	"velocity_z",
	"aim_x",
	"aim_z",
	"reload_remaining",
	"shot_cooldown",
	"dash_remaining",
	"dash_direction_x",
	"dash_direction_z",
	"last_move_direction_x",
	"last_move_direction_z",
	"shooting_slow_remaining",
	"hurt_immunity_remaining",
	"grounded",
	"dead",
	"edge_negative_x",
	"edge_positive_x",
	"edge_negative_z",
	"edge_positive_z",
	"cursor_x",
	"cursor_z",
	"cursor_velocity_x",
	"cursor_velocity_z",
]
const ENEMY_OBSERVATION_FIELDS := [
	"present",
	"relative_x",
	"relative_y",
	"relative_z",
	"velocity_x",
	"velocity_z",
	"hound",
	"climbing",
	"velocity_y",
	"health",
	"heading_x",
	"heading_z",
	"chasing",
	"warning",
	"charging",
	"skidding",
	"fallen",
	"recovering",
	"attacking",
	"state_remaining",
	"charge_cooldown",
	"attack_cooldown",
	"grace_remaining",
	"collision_stumble_cooldown",
	"balance_stress",
	"charge_direction_x",
	"charge_direction_z",
	"run_speed",
	"charge_speed",
	"turn_speed",
	"climb_remaining",
]
# Where the weapon pivot sits relative to the first-person camera: close enough for the arms to reach.
const FPS_WEAPON_OFFSET := Vector3(-0.14, -0.48, 0.07)
# Rolls the rifle so its textured side faces the camera instead of its stretched top.
const FPS_WEAPON_CANT := deg_to_rad(-20.0)



@export var ai_controlled :=false
var ai_move := Vector2.ZERO
# The AI aims like a person with a mouse: it moves a cursor over the ground and
# the gun points at it, as aim_at_mouse() does. ai_mouse is how hard it pushes
# the mouse (-1..1 per axis: right is world +X, down is world +Z). The cursor's
# speed and acceleration are capped, so aim is continuous and can't snap.
var ai_mouse := Vector2.ZERO
@export var ai_cursor_max_speed := 60.0
@export var ai_cursor_acceleration := 600.0
var ai_cursor := Vector2.ZERO
var ai_cursor_velocity := Vector2.ZERO
# The cursor stays on screen: roughly the ground the overhead camera shows.
const AI_CURSOR_BOUNDS := Rect2(-22.0, -16.0, 44.0, 32.0)
@export var debug_observations := true
var observation_print_cooldown := 0.0
# Shooting is held; reload and dash requests are consumed once per physics tick.
var ai_shoot := false
var ai_reload_requested := false
var ai_dash_requested := false
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
@export_group("Recoil")
@export var recoil_camera_pitch_degrees := 1.4
@export var recoil_camera_side_degrees := 0.2
@export var recoil_camera_return_speed := 6.0
@export var recoil_weapon_pitch_degrees := 7.0
@export var recoil_weapon_back_distance := 0.12
@export var recoil_weapon_return_speed := 14.0
var camera_recoil := Vector2.ZERO
var weapon_recoil := 0.0
var recoil_side := 1.0
var gun_rest: Transform3D
var muzzle_rest: Transform3D
@onready var gun_model: Node3D = $WeaponPivot/GunModel
@onready var muzzle_marker: Marker3D = $WeaponPivot/Muzzle
@onready var fps_rig: Node3D = $FirstPersonRig
@onready var fps_camera: Camera3D = $FirstPersonRig/FirstPersonCamera
@onready var overhead_camera: Camera3D = get_parent().get_node("Camera3D")
@onready var shoot_sound: AudioStreamPlayer = $ShootSound
@onready var reload_sound: AudioStreamPlayer = $ReloadSound
@onready var empty_sound: AudioStreamPlayer = $EmptySound
@onready var hurt_sound: AudioStreamPlayer = $HurtSound
var crosshair: Label

func _ready() -> void:
	var start_aim: Vector3 = -$WeaponPivot.global_basis.z
	ai_cursor = Vector2(global_position.x + start_aim.x * 5.0, global_position.z + start_aim.z * 5.0)
	gun_rest = gun_model.transform
	muzzle_rest = muzzle_marker.transform
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
	if ai_controlled:
		return
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
	if ai_controlled and enabled:
		return
	reset_recoil()
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
	fps_rig.rotation = Vector3(
		clampf(look_pitch + camera_recoil.x, deg_to_rad(-80), deg_to_rad(80)),
		look_yaw + camera_recoil.y, 0
	)
	$WeaponPivot.global_transform = Transform3D(fps_camera.global_basis * Basis(Vector3.BACK, FPS_WEAPON_CANT), fps_camera.global_transform * FPS_WEAPON_OFFSET)

# A future visual-learning adapter can use this camera, not enemy coordinates.
func get_observation_camera() -> Camera3D:
	return fps_camera

func _physics_process(delta: float) -> void:
	# Also restore overhead view if AI mode is enabled while already in FPS.
	if ai_controlled and fps_mode:
		set_fps_mode(false)
	if dead:
		return
	if debug_observations:
		observation_print_cooldown -= delta
		if observation_print_cooldown <= 0.0:
			observation_print_cooldown = 1.0
			print_observation_debug()
	update_recoil(delta)
	hurt_cooldown = maxf(0.0, hurt_cooldown - delta)
	player_material.albedo_color = Color(1, 0.2, 0.15) if hurt_cooldown > 0.25 else Color(0.236, 0.414, 1)
	if global_position.y < -8.0:
		take_damage(100.0)
		return
	if not is_on_floor():
		velocity.y -= gravity * delta
		
	else:
		velocity.y =0.0

	var direction: Vector2
	if ai_controlled:
		direction = ai_move.limit_length(1.0)
	else:
		direction = Input.get_vector(
			"move_left", "move_right","move_up", "move_down"
		)
	
	var movement := Vector3(direction.x, 0, direction.y)
	if fps_mode:
		movement = movement.rotated(Vector3.UP, look_yaw)
	if movement.length_squared() > 0.01:
		last_move_direction = movement.normalized()
	dash_cooldown_left = maxf(0.0, dash_cooldown_left - delta)
	dash_time_left = maxf(0.0, dash_time_left - delta)
	shooting_slow_time = maxf(0.0, shooting_slow_time - delta)
	var dash_requested := ai_dash_requested if ai_controlled else Input.is_action_just_pressed("dash")
	ai_dash_requested = false
	if dash_requested:
		start_dash(movement)
	if fps_mode:
		update_fps_pose()
	else:
		if ai_controlled:
			aim_at_ai_cursor(delta)
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
			
# Same rule as aim_at_mouse(), with the AI's cursor instead of the real one.
func aim_at_ai_cursor(delta: float) -> void:
	# Speed builds up and dies down like a hand on a mouse; no teleporting.
	var wanted := ai_mouse.limit_length(1.0) * ai_cursor_max_speed
	ai_cursor_velocity = ai_cursor_velocity.move_toward(wanted, ai_cursor_acceleration * delta)
	ai_cursor += ai_cursor_velocity * delta
	var on_screen := ai_cursor.clamp(AI_CURSOR_BOUNDS.position, AI_CURSOR_BOUNDS.end)
	if on_screen.x != ai_cursor.x:
		ai_cursor_velocity.x = 0.0
	if on_screen.y != ai_cursor.y:
		ai_cursor_velocity.y = 0.0
	ai_cursor = on_screen
	var target := Vector3(ai_cursor.x, $WeaponPivot.global_position.y, ai_cursor.y)
	if $WeaponPivot.global_position.distance_to(target) > 0.01:
		$WeaponPivot.look_at(target, Vector3.UP)

func handle_shooting(delta: float) -> void:
	shot_cooldown = maxf(0.0, shot_cooldown - delta)
	if dash_time_left > 0.0:
		return
	if fps_mode and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	var shoot_requested := ai_shoot if ai_controlled else Input.is_action_pressed("shoot")
	if shoot_requested and shot_cooldown <= 0.0:
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
	var reload_requested := ai_reload_requested if ai_controlled else Input.is_action_just_pressed("reload")
	ai_reload_requested = false
	if reloading:
		reload_time_left -= delta
		if reload_time_left <= 0.0:
			finish_reload()
	elif reload_requested:
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
	# Overhead aim stays on the mouse plane; cosmetic barrel kick adds no vertical spread.
	bullet.direction = -$WeaponPivot.global_basis.z.normalized()
	if fps_mode:
		var origin := fps_camera.global_position
		var target := origin - fps_camera.global_basis.z * 100.0
		var query := PhysicsRayQueryParameters3D.create(origin, target)
		query.exclude = [get_rid()]
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		if not hit.is_empty():
			target = hit.position
		bullet.direction = (target - muzzle.global_position).normalized()
	# Apply kick after choosing this shot's aim. Subsequent FPS shots use the kicked camera.
	add_recoil()

func add_recoil() -> void:
	weapon_recoil = minf(weapon_recoil + 1.0, 1.7)
	if fps_mode:
		camera_recoil.x = minf(camera_recoil.x + deg_to_rad(recoil_camera_pitch_degrees), deg_to_rad(5.0))
		camera_recoil.y = clampf(camera_recoil.y + deg_to_rad(recoil_camera_side_degrees) * recoil_side, deg_to_rad(-0.8), deg_to_rad(0.8))
		update_fps_pose()
	recoil_side *= -1.0
	apply_weapon_recoil()

func update_recoil(delta: float) -> void:
	# Exponential return behaves consistently at different frame rates.
	weapon_recoil *= exp(-recoil_weapon_return_speed * delta)
	camera_recoil *= exp(-recoil_camera_return_speed * delta)
	if weapon_recoil < 0.001:
		weapon_recoil = 0.0
	if camera_recoil.length_squared() < 0.00000001:
		camera_recoil = Vector2.ZERO
	apply_weapon_recoil()

func apply_weapon_recoil() -> void:
	var kick := Transform3D(
		Basis.from_euler(Vector3(deg_to_rad(recoil_weapon_pitch_degrees) * weapon_recoil, 0, 0)),
		Vector3(0, 0, recoil_weapon_back_distance * weapon_recoil)
	)
	gun_model.transform = gun_rest * kick
	# Keep the muzzle attached to the moving barrel. Existing arm IK follows GunModel.
	muzzle_marker.transform = gun_model.transform * gun_rest.affine_inverse() * muzzle_rest

func reset_recoil() -> void:
	camera_recoil = Vector2.ZERO
	weapon_recoil = 0.0
	recoil_side = 1.0
	apply_weapon_recoil()
	if fps_mode:
		update_fps_pose()

func take_damage(amount: float) -> void:
	if dead or hurt_cooldown > 0.0:
		return
	health = maxf(0.0, health - amount)
	hurt_cooldown = 0.45
	hurt_sound.play()
	if health <= 0.0:
		dead = true
		ai_move = Vector2.ZERO
		ai_mouse = Vector2.ZERO
		ai_cursor_velocity = Vector2.ZERO
		ai_shoot = false
		ai_reload_requested = false
		ai_dash_requested = false
		reset_recoil()
		velocity = Vector3.ZERO
		player_material.albedo_color = Color(0.25, 0.25, 0.3)
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


# Fixed, normalized numeric inputs. All enemies in the group are observable,
# including those climbing outside the camera view. Dead enemies leave the group.
func get_observation() -> Array[float]:
	var observation := get_player_observation()
	var enemies := get_observed_enemies()
	for i in range(MAX_OBSERVED_ENEMIES):
		if i < enemies.size():
			observation.append_array(get_enemy_observation(enemies[i]))
		else:
			for unused in range(ENEMY_OBSERVATION_FIELDS.size()):
				observation.append(0.0)
	return observation

func get_observed_enemies() -> Array[Node]:
	var enemies := get_tree().get_nodes_in_group("zombies")
	enemies.sort_custom(func(a, b):
		var distance_a: float = global_position.distance_squared_to(a.global_position)
		var distance_b: float = global_position.distance_squared_to(b.global_position)
		if distance_a == distance_b:
			return a.get_instance_id() < b.get_instance_id()
		return distance_a < distance_b
	)
	return enemies

func get_player_observation() -> Array[float]:
	var aim: Vector3 = -$WeaponPivot.global_basis.z.normalized()
	return [
		observation_ratio(health, 100.0),
		observation_ratio(float(ammo_in_magazine), float(magazine_size)),
		observation_ratio(float(reserve_ammo), 48.0),
		1.0 if reloading else 0.0,
		observation_ratio(dash_cooldown_left, dash_cooldown_duration),
		observation_signed(global_position.x, 16.0),
		observation_signed(global_position.y, 64.0),
		observation_signed(global_position.z, 10.0),
		observation_signed(velocity.x, 15.0),
		observation_signed(velocity.y, 25.0),
		observation_signed(velocity.z, 15.0),
		aim.x, aim.z,
		observation_ratio(reload_time_left, reload_duration) if reloading else 0.0,
		observation_ratio(shot_cooldown, 0.35),
		observation_ratio(dash_time_left, dash_duration),
		dash_direction.x, dash_direction.z,
		last_move_direction.x, last_move_direction.z,
		observation_ratio(shooting_slow_time, 0.22),
		observation_ratio(hurt_cooldown, 0.45),
		1.0 if is_on_floor() else 0.0,
		1.0 if dead else 0.0,
		observation_signed(global_position.x + 16.0, 32.0),
		observation_signed(16.0 - global_position.x, 32.0),
		observation_signed(global_position.z + 10.0, 20.0),
		observation_signed(10.0 - global_position.z, 20.0),
		# Cursor relative to the player, on the same scales as enemy positions.
		observation_signed(ai_cursor.x - global_position.x, 32.0),
		observation_signed(ai_cursor.y - global_position.z, 20.0),
		observation_signed(ai_cursor_velocity.x, ai_cursor_max_speed),
		observation_signed(ai_cursor_velocity.y, ai_cursor_max_speed)
	]

func get_enemy_observation(enemy: Node3D) -> Array[float]:
	var relative_position: Vector3 = enemy.global_position - global_position
	var observed_velocity := get_enemy_observed_velocity(enemy)
	var active_state: String = "climbing" if enemy.climbing else enemy.state
	var charge_active: bool = enemy.is_hound and active_state in ["windup", "charge"]
	var charge_direction: Vector3 = enemy.locked_charge if charge_active else Vector3.ZERO
	var climb_remaining: float = maxf(0.0, enemy.rush_duration + enemy.climb_duration + 0.8 - enemy.climb_time) if enemy.climbing else 0.0
	return [
		1.0,
		observation_signed(relative_position.x, 32.0),
		observation_signed(relative_position.y, 64.0),
		observation_signed(relative_position.z, 20.0),
		observation_signed(observed_velocity.x, 15.0),
		observation_signed(observed_velocity.z, 15.0),
		1.0 if enemy.is_hound else 0.0,
		1.0 if enemy.climbing else 0.0,
		observation_signed(observed_velocity.y, 25.0),
		observation_ratio(enemy.health, 50.0 if enemy.is_hound else 75.0),
		enemy.heading.x, enemy.heading.z,
		1.0 if active_state == "chase" else 0.0,
		1.0 if active_state == "windup" else 0.0,
		1.0 if active_state == "charge" else 0.0,
		1.0 if active_state == "skid" else 0.0,
		1.0 if active_state == "fallen" else 0.0,
		1.0 if active_state == "recover" else 0.0,
		1.0 if active_state == "attack" else 0.0,
		observation_ratio(enemy.state_time, 3.0) if not enemy.climbing else 0.0,
		observation_ratio(enemy.charge_cooldown, 2.0) if enemy.is_hound else 0.0,
		observation_ratio(enemy.attack_cooldown, 0.9),
		observation_ratio(enemy.grace_time, 1.0),
		observation_ratio(enemy.collision_stumble_cooldown, 4.0),
		observation_ratio(enemy.balance_stress, 0.65),
		charge_direction.x, charge_direction.z,
		observation_ratio(enemy.speed, 15.0),
		observation_ratio(enemy.charge_speed, 15.0) if enemy.is_hound else 0.0,
		observation_ratio(enemy.turn_speed, PI),
		observation_ratio(climb_remaining, enemy.rush_duration + enemy.climb_duration + 0.8)
	]

func get_enemy_observed_velocity(enemy: Node3D) -> Vector3:
	# Climbing sets position directly, so CharacterBody3D.velocity stays stale.
	if enemy.climbing:
		var climb_phase: float = enemy.climb_time - enemy.rush_duration
		if climb_phase < 0.0 and enemy.rush_duration > 0.0:
			return (enemy.climb_reveal - enemy.climb_start) / enemy.rush_duration
		if climb_phase < enemy.climb_duration and enemy.climb_duration > 0.0:
			return (enemy.climb_top - enemy.climb_reveal) / enemy.climb_duration
		var progress := clampf((climb_phase - enemy.climb_duration) / 0.8, 0.0, 1.0)
		return (enemy.landing - enemy.climb_top) * (6.0 * progress * (1.0 - progress) / 0.8)
	# Read the hips' actual velocity when fallen; do not modify ragdoll physics.
	if is_instance_valid(enemy.ragdoll):
		var hips: int = enemy.ragdoll.skeleton.find_bone("Hips")
		if enemy.ragdoll.bodies.has(hips):
			return enemy.ragdoll.bodies[hips].linear_velocity
	return Vector3(enemy.momentum.x, enemy.velocity.y, enemy.momentum.z)

func observation_ratio(value: float, scale: float) -> float:
	return clampf(value / maxf(scale, 0.001), 0.0, 1.0)

func observation_signed(value: float, scale: float) -> float:
	return clampf(value / maxf(scale, 0.001), -1.0, 1.0)

func print_observation_debug() -> void:
	var enemies := get_observed_enemies()
	var values := get_player_observation()
	var player_data := {}
	for i in range(PLAYER_OBSERVATION_FIELDS.size()):
		player_data[PLAYER_OBSERVATION_FIELDS[i]] = values[i]
	print("AI observation: ", PLAYER_OBSERVATION_FIELDS.size() + MAX_OBSERVED_ENEMIES * ENEMY_OBSERVATION_FIELDS.size(), " values; ", mini(enemies.size(), MAX_OBSERVED_ENEMIES), " enemies")
	print("Player: ", player_data)
	if not enemies.is_empty():
		values = get_enemy_observation(enemies[0])
		var enemy_data := {}
		for i in range(ENEMY_OBSERVATION_FIELDS.size()):
			enemy_data[ENEMY_OBSERVATION_FIELDS[i]] = values[i]
		print("Nearest enemy: ", enemy_data)
	for enemy in enemies.slice(0, MAX_OBSERVED_ENEMIES):
		if enemy.is_hound:
			print("Hound ", enemy.get_instance_id(), ": ", "climbing" if enemy.climbing else enemy.state, "; phase remaining: ", maxf(0.0, enemy.state_time), "s; charge cooldown: ", maxf(0.0, enemy.charge_cooldown), "s")
