extends CharacterBody3D

var speed: float = 25.0
var direction: Vector3 = Vector3.FORWARD
var lifetime: float = 2.0
var damage: float = 25.0
var distance_travelled: float = 0.0

@onready var trail: MeshInstance3D = $Trail

func _physics_process(delta: float) -> void:
	lifetime -= delta
	if lifetime <= 0.0:
		queue_free()
		return

	var heading := direction.normalized()
	if heading.length_squared() < 0.001:
		return
	look_at(global_position + heading, Vector3.UP)
	var previous_position := global_position
	var collision := move_and_collide(heading * speed * delta)
	distance_travelled += global_position.distance_to(previous_position)

	# Grow behind the projectile, without extending behind its spawn point.
	var trail_length := minf(distance_travelled, 0.9)
	trail.visible = trail_length > 0.01
	trail.scale.z = maxf(trail_length, 0.001)
	trail.position.z = trail_length * 0.5

	if collision:
		var target := collision.get_collider()
		if target.has_method("receive_projectile_hit"):
			target.receive_projectile_hit(damage, heading)
		elif target.has_method("take_damage"):
			target.take_damage(damage)
		queue_free()
