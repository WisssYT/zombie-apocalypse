extends CharacterBody3D

@export var is_hound := false
@export var speed := 6.3
@export var acceleration := 9.0
@export var turn_speed := 1.65
@export var safe_lateral_acceleration := 8.5
@export var charge_speed := 14.0
@export var warning_duration := 0.8
@export var recovery_duration := 1.3

var player: Node3D
var health := 75.0
var dead := false
var climbing := true
var climb_start := Vector3.ZERO
var climb_top := Vector3.ZERO
var landing := Vector3.ZERO
var climb_time := 0.0
var climb_duration := 5.0
var heading := Vector3.FORWARD
var momentum := Vector3.ZERO
var state := "chase"
var state_time := 0.0
var balance_stress := 0.0
var grace_time := 0.7
var charge_cooldown := 0.0
var locked_charge := Vector3.FORWARD
var attack_cooldown := 0.0
var hit_flash := 0.0
var age := 0.0
var animator: AnimationPlayer
var active_animation := ""
var meshes: Array[MeshInstance3D] = []
@onready var visuals: Node3D = $Visuals
@onready var marker: MeshInstance3D = $StateRing
@onready var warning: MeshInstance3D = $ChargeWarning
@onready var hit_sound: AudioStreamPlayer = $HitSound

func _ready() -> void:
	add_to_group("zombies")
	if is_hound:
		add_to_group("hounds")
		health = 50.0
		visuals.scale = Vector3.ONE * 1.4
	var model_path := "res://models/bitkiln/"
	if is_hound:
		model_path += "hound_flayed.glb" if randf() < 0.5 else "hound_black.glb"
	else:
		model_path += "shambler_worker.glb" if randf() < 0.5 else "shambler_patient.glb"
	var model: Node3D = load(model_path).instantiate()
	# Imported models face +Z; our controller faces -Z.
	model.rotation.y = PI
	visuals.add_child(model)
	animator = model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	collect_meshes(model)
	if animator:
		for clip in ["Idle", "Walk", "Run"]:
			if animator.has_animation(clip):
				animator.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
	marker.material_override = marker.material_override.duplicate()
	collision_layer = 1
	collision_mask = 0 if climbing else 1
	play_clip("Walk", 0.8)

func collect_meshes(node: Node) -> void:
	if node is MeshInstance3D:
		meshes.append(node)
		for surface in range(node.mesh.get_surface_count()):
			var source = node.get_active_material(surface)
			if source is StandardMaterial3D:
				var material: StandardMaterial3D = source.duplicate()
				material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
				node.set_surface_override_material(surface, material)
	for child in node.get_children():
		collect_meshes(child)

func play_clip(clip: String, rate := 1.0) -> void:
	if not animator or not animator.has_animation(clip):
		return
	if active_animation != clip:
		animator.play(clip, 0.12)
		active_animation = clip
	animator.speed_scale = rate

func _physics_process(delta: float) -> void:
	if dead:
		return
	if not is_instance_valid(player) or player.dead:
		warning.hide()
		play_clip("Idle")
		return
	age += delta
	hit_flash = maxf(0.0, hit_flash - delta)
	if climbing:
		update_climb(delta)
		return
	grace_time = maxf(0.0, grace_time - delta)
	attack_cooldown = maxf(0.0, attack_cooldown - delta)
	charge_cooldown = maxf(0.0, charge_cooldown - delta)
	state_time = maxf(0.0, state_time - delta)
	var target: Vector3 = player.global_position - global_position
	target.y = 0.0
	if state == "chase":
		if is_hound and target.length() < 8.5 and charge_cooldown <= 0.0 and grace_time <= 0.0:
			begin_charge_warning(target)
		else:
			steer_toward(target, delta)
	elif state == "windup":
		momentum = Vector3.ZERO
		play_clip("Howl", 2.8)
		if state_time <= 0.0:
			state = "charge"
			state_time = 0.65
			warning.hide()
	elif state == "charge":
		momentum = locked_charge * charge_speed
		play_clip("Run", 2.0)
		if state_time <= 0.0:
			begin_recovery()
	elif state in ["skid", "fallen", "recover", "attack"]:
		momentum = momentum.move_toward(Vector3.ZERO, (9.0 if state == "skid" else 16.0) * delta)
		if state == "fallen":
			visuals.rotation.z = lerpf(visuals.rotation.z, 1.3, minf(1.0, delta * 12))
			visuals.position.y = -0.9
			play_clip("Hit", 0.4)
		elif state == "skid":
			visuals.rotation.z = sin(age * 16.0) * 0.2
			play_clip("Walk", 0.5)
		elif state == "recover":
			play_clip("Idle", 0.7)
		if state_time <= 0.0:
			state = "chase"
			balance_stress = 0.0
			grace_time = 0.6
			visuals.rotation = Vector3.ZERO
			visuals.position.y = -1.0
	velocity.x = momentum.x
	velocity.z = momentum.z
	velocity.y = 0.0 if is_on_floor() else velocity.y - 9.8 * delta
	move_and_slide()
	face_heading()
	if state == "charge":
		if can_hit_player(1.35):
			player.take_damage(18.0)
			begin_recovery()
		elif is_on_wall():
			begin_recovery()
	elif not is_hound and state == "chase" and attack_cooldown <= 0.0 and can_hit_player(1.4):
		player.take_damage(10.0)
		attack_cooldown = 0.9
		state = "attack"
		state_time = 0.6
		play_clip("Attack", 1.7)
	update_marker()
	if global_position.y < -16.0:
		queue_free()

func steer_toward(target: Vector3, delta: float) -> void:
	if target.length_squared() < 0.001:
		return
	var desired := target.normalized()
	var error := heading.signed_angle_to(desired, Vector3.UP)
	var turn := clampf(error, -turn_speed * delta, turn_speed * delta)
	heading = heading.rotated(Vector3.UP, turn).normalized()
	momentum = momentum.move_toward(heading * speed, acceleration * delta)
	play_clip("Run", 1.7 if not is_hound else 1.8)
	# Tight high-speed turns accumulate load; wide curves shed it.
	var lateral_load := momentum.length() * absf(turn) / maxf(delta, 0.001)
	if not is_hound and grace_time <= 0.0 and momentum.length() > speed * 0.72 and absf(error) > 0.7:
		balance_stress = maxf(0.0, balance_stress + (lateral_load - safe_lateral_acceleration) * delta)
	else:
		balance_stress = maxf(0.0, balance_stress - 4.0 * delta)
	if balance_stress > 0.65:
		state = "fallen" if absf(error) > 1.85 else "skid"
		state_time = 1.35 if state == "fallen" else 0.85
		balance_stress = 0.0

func begin_charge_warning(target: Vector3) -> void:
	state = "windup"
	state_time = warning_duration
	locked_charge = target.normalized() if target.length_squared() > 0.001 else heading
	heading = locked_charge
	momentum = Vector3.ZERO
	face_heading()
	warning.show()
	# This line is fixed when the warning starts. It never tracks a dodge.
	warning.global_position = global_position + locked_charge * (charge_speed * 0.65 * 0.5)
	warning.global_position.y = -0.44
	warning.global_rotation = Vector3(0, rotation.y, 0)

func begin_recovery() -> void:
	state = "recover"
	state_time = recovery_duration
	charge_cooldown = 2.0
	warning.hide()

func face_heading() -> void:
	if heading.length_squared() > 0.001:
		rotation.y = atan2(-heading.x, -heading.z)

func can_hit_player(reach: float) -> bool:
	var offset: Vector3 = player.global_position - global_position
	if absf(offset.y) > 1.0:
		return false
	offset.y = 0.0
	if offset.length() > reach:
		return false
	var query := PhysicsRayQueryParameters3D.create(global_position, player.global_position)
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return not hit.is_empty() and hit.collider == player

func update_marker() -> void:
	marker.visible = state in ["windup", "charge", "skid", "fallen", "recover"] or hit_flash > 0.0
	var color := Color(1.0, 0.65, 0.1)
	if state == "charge":
		color = Color(1.0, 0.12, 0.06)
	elif state in ["recover", "fallen"]:
		color = Color(0.3, 0.85, 1.0)
	elif hit_flash > 0.0:
		color = Color(1.0, 0.95, 0.7)
	marker.material_override.albedo_color = color

func update_climb(delta: float) -> void:
	climb_time += delta
	play_clip("Walk", 1.2)
	if climb_time < climb_duration:
		global_position = climb_start.lerp(climb_top, clampf(climb_time / climb_duration, 0, 1))
		visuals.rotation.x = -0.25
		visuals.rotation.z = sin(climb_time * 6) * 0.09
	else:
		var progress := smoothstep(climb_duration, climb_duration + 0.8, climb_time)
		global_position = climb_top.lerp(landing, progress)
		visuals.rotation.x = -sin(progress * PI) * 0.5
	if climb_time >= climb_duration + 0.8:
		climbing = false
		collision_mask = 1
		visuals.rotation = Vector3.ZERO
		heading = landing - climb_top
		heading.y = 0
		heading = heading.normalized()
		face_heading()

func take_damage(amount: float) -> void:
	if dead:
		return
	health -= amount
	hit_flash = 0.15
	hit_sound.play()
	if health <= 0.0:
		dead = true
		climbing = false
		warning.hide()
		marker.hide()
		collision_layer = 0
		collision_mask = 0
		remove_from_group("zombies")
		if is_in_group("hounds"):
			remove_from_group("hounds")
		get_tree().current_scene.register_kill()
		visuals.rotation = Vector3.ZERO
		visuals.position.y = -1.0
		play_clip("Death")
		get_tree().create_timer(2.4).timeout.connect(queue_free)
