extends Node3D

@onready var player = get_parent()
@onready var model: Node3D = $Model
var animator: AnimationPlayer
var skeleton: Skeleton3D
var current_clip := ""
var meshes: Array[MeshInstance3D] = []
var flash_material: StandardMaterial3D

func _ready() -> void:
	animator = model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	skeleton = model.find_child("Skeleton3D", true, false) as Skeleton3D
	if animator:
		animator.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		for clip in ["idle", "walk", "run"]:
			if animator.has_animation(clip):
				animator.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
	flash_material = StandardMaterial3D.new()
	flash_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flash_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	flash_material.albedo_color = Color(1.0, 0.12, 0.05, 0.6)
	collect_meshes(model)

func collect_meshes(node: Node) -> void:
	if node is MeshInstance3D:
		node.layers = 2
		meshes.append(node)
		for surface in range(node.mesh.get_surface_count()):
			var source = node.get_active_material(surface)
			if source is StandardMaterial3D:
				var material: StandardMaterial3D = source.duplicate()
				material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
				material.vertex_color_use_as_albedo = true
				# Preserve the baked texture detail on the unlit side of the arena.
				material.emission_enabled = true
				material.emission_texture = material.albedo_texture
				material.emission = Color(0.22, 0.22, 0.22)
				node.set_surface_override_material(surface, material)
	for child in node.get_children():
		collect_meshes(child)

func _process(delta: float) -> void:
	if not animator:
		return
	var horizontal_speed := Vector2(player.velocity.x, player.velocity.z).length()
	var clip := "idle"
	var rate := 1.0
	if player.dead:
		clip = "death"
	elif horizontal_speed > 0.15:
		clip = "run" if horizontal_speed > 3.2 else "walk"
		rate = clampf(horizontal_speed / (4.0 if clip == "run" else 2.0), 0.65, 1.8)
	if clip != current_clip:
		animator.play(clip, 0.12)
		current_clip = clip
	animator.speed_scale = rate
	animator.advance(delta)
	for mesh in meshes:
		mesh.material_overlay = flash_material if player.hurt_cooldown > 0.25 and not player.dead else null
	if player.dead:
		return
	rotation.y = player.look_yaw if player.fps_mode else player.get_node("WeaponPivot").rotation.y
	# Pose the arms after advancing the leg animation, keeping the rifle in hand.
	if skeleton:
		point_bone("RightArm", Vector3(-0.12, -0.16, 0.2))
		point_bone("RightForeArm", Vector3(0.0, -0.02, 0.28))
		point_bone("LeftArm", Vector3(-0.18, -0.17, 0.14))
		point_bone("LeftForeArm", Vector3(-0.17, 0.02, 0.25))
		if player.reloading:
			var progress: float = 1.0 - player.reload_time_left / player.reload_duration
			point_bone("LeftForeArm", Vector3(-0.07, -0.18 * sin(progress * PI), 0.25))

func point_bone(bone_name: String, direction: Vector3) -> void:
	var bone := skeleton.find_bone(bone_name)
	if bone < 0:
		return
	var pose := skeleton.get_bone_global_pose(bone)
	pose.basis = Basis(Quaternion(Vector3.UP, direction.normalized()))
	skeleton.set_bone_global_pose(bone, pose)
