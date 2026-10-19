extends CharacterBody3D

var health: float = 75.0
var speed: float = 1.7
var player: Node3D
var climbing := true
var climb_start := Vector3.ZERO
var climb_top := Vector3.ZERO
var landing := Vector3.ZERO
var climb_time := 0.0
var climb_duration := 5.0
var attack_cooldown := 0.0
var flash_time := 0.0
var age := 0.0
var dead := false
var skin: StandardMaterial3D

func _ready() -> void:
	add_to_group("zombies")
	skin = StandardMaterial3D.new()
	skin.albedo_color = Color(0.24, 0.65, 0.12)
	$Body.material_override = skin
	collision_layer = 1
	collision_mask = 0 if climbing else 1

func _physics_process(delta: float) -> void:
	if dead:
		return
	if not is_instance_valid(player) or player.dead:
		return
	age += delta
	flash_time = maxf(0.0, flash_time - delta)
	skin.albedo_color = Color(1.0, 0.85, 0.35) if flash_time > 0.0 else Color(0.24, 0.65, 0.12)
	if climbing:
		climb_time += delta
		if climb_time < climb_duration:
			var progress := clampf(climb_time / climb_duration, 0.0, 1.0)
			global_position = climb_start.lerp(climb_top, progress)
			# Alternating reaches and body sway make each upward pull visible.
			var stroke := sin(climb_time * 6.0)
			$LeftArm.rotation.x = -0.9 + stroke * 0.4
			$RightArm.rotation.x = -0.9 - stroke * 0.4
			$LeftArm.position.y = 0.45 + stroke * 0.18
			$RightArm.position.y = 0.45 - stroke * 0.18
			$Body.rotation.z = stroke * 0.09
		else:
			var mantle := smoothstep(climb_duration, climb_duration + 0.8, climb_time)
			global_position = climb_top.lerp(landing, mantle)
			$Body.rotation.x = sin(mantle * PI) * -0.45
		if climb_time >= climb_duration + 0.8:
			climbing = false
			collision_mask = 1
			$Body.rotation = Vector3.ZERO
			$LeftArm.rotation = Vector3.ZERO
			$RightArm.rotation = Vector3.ZERO
			$LeftArm.position.y = 0.18
			$RightArm.position.y = 0.18
		return
	attack_cooldown = maxf(0.0, attack_cooldown - delta)
	var offset: Vector3 = player.global_position - global_position
	offset.y = 0.0
	var heading := offset.normalized()
	if offset.length() > 0.01:
		look_at(global_position + heading, Vector3.UP)
	velocity.x = heading.x * speed if offset.length() > 1.05 else 0.0
	velocity.z = heading.z * speed if offset.length() > 1.05 else 0.0
	velocity.y = 0.0 if is_on_floor() else velocity.y - 9.8 * delta
	move_and_slide()
	$Body.rotation.z = sin(age * 7.0) * 0.045
	if offset.length() < 1.35 and absf(player.global_position.y - global_position.y) < 1.0 and attack_cooldown <= 0.0:
		var query := PhysicsRayQueryParameters3D.create(global_position, player.global_position)
		query.exclude = [get_rid()]
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		if not hit.is_empty() and hit.collider == player:
			player.take_damage(10.0)
			attack_cooldown = 1.0
	if global_position.y < -12.0:
		queue_free()

func take_damage(amount: float) -> void:
	if dead:
		return
	health -= amount
	flash_time = 0.12
	if health <= 0.0:
		dead = true
		var death_sound := AudioStreamPlayer.new()
		death_sound.stream = $HitSound.stream
		death_sound.volume_db = -9.0
		get_tree().current_scene.add_child(death_sound)
		death_sound.finished.connect(death_sound.queue_free)
		death_sound.play()
		get_tree().current_scene.register_kill()
		queue_free()
	else:
		$HitSound.play()
