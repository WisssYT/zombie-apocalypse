extends Node3D
## First-person arms: a copy of the survivor that only the first-person camera draws (layer 11).
## Its head and legs are shrunk away, and two-bone IK keeps both hands on the rifle.

const FIRST_PERSON_LAYER := 1 << 10
# Wrist targets in GunModel space, read off the AK-74 mesh.
const GRIP := Vector3(0.0, -0.1, 0.13)
const HANDGUARD := Vector3(0.0, 0.0, -0.36)
const MAGAZINE := Vector3(0.0, -0.3, -0.12)

@onready var pivot: Node3D = get_parent()
@onready var player = pivot.get_parent()
@onready var gun: Node3D = pivot.get_node("GunModel")
@onready var model: Node3D = $Model
var skeleton: Skeleton3D

func _ready() -> void:
	skeleton = model.find_child("Skeleton3D", true, false) as Skeleton3D
	var animator := model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if animator:
		animator.stop()
	for bone in ["Head", "LeftUpLeg", "RightUpLeg"]:
		skeleton.set_bone_pose_scale(skeleton.find_bone(bone), Vector3.ONE * 0.001)
	setup_meshes(model)

func setup_meshes(node: Node) -> void:
	if node is MeshInstance3D:
		node.layers = FIRST_PERSON_LAYER
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		for surface in range(node.mesh.get_surface_count()):
			var source = node.get_active_material(surface)
			if source is StandardMaterial3D:
				# Same look as the third-person survivor.
				var material: StandardMaterial3D = source.duplicate()
				material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
				material.vertex_color_use_as_albedo = true
				material.emission_enabled = true
				material.emission_texture = material.albedo_texture
				material.emission = Color(0.22, 0.22, 0.22)
				node.set_surface_override_material(surface, material)
	for child in node.get_children():
		setup_meshes(child)

func _process(_delta: float) -> void:
	visible = player.fps_mode and not player.dead
	if not visible:
		return
	var left_target := HANDGUARD
	if player.reloading:
		var progress: float = 1.0 - player.reload_time_left / player.reload_duration
		left_target = HANDGUARD.lerp(MAGAZINE, sin(progress * PI))
	# Poles push the elbows down and out, like a shouldered rifle.
	reach("RightArm", "RightForeArm", "RightHand", gun.transform * GRIP, Vector3(1.0, -1.0, 0.3))
	reach("LeftArm", "LeftForeArm", "LeftHand", gun.transform * left_target, Vector3(-0.6, -1.0, 0.0))

func reach(upper_name: String, lower_name: String, hand_name: String, target: Vector3, pole: Vector3) -> void:
	# target and pole are in WeaponPivot space; the bones are solved in skeleton space.
	var to_skeleton: Transform3D = skeleton.global_transform.affine_inverse() * pivot.global_transform
	var upper := skeleton.find_bone(upper_name)
	var lower := skeleton.find_bone(lower_name)
	var hand := skeleton.find_bone(hand_name)
	var upper_length := skeleton.get_bone_rest(lower).origin.length()
	var lower_length := skeleton.get_bone_rest(hand).origin.length()
	var shoulder := skeleton.get_bone_global_pose(upper).origin
	var offset := to_skeleton * target - shoulder
	var distance := clampf(offset.length(), 0.05, (upper_length + lower_length) * 0.999)
	var direction := offset.normalized()
	var bend_axis := to_skeleton.basis * pole
	bend_axis = (bend_axis - direction * bend_axis.dot(direction)).normalized()
	var cos_shoulder := clampf((upper_length * upper_length + distance * distance - lower_length * lower_length) / (2.0 * upper_length * distance), -1.0, 1.0)
	var elbow := shoulder + direction * upper_length * cos_shoulder + bend_axis * upper_length * sqrt(1.0 - cos_shoulder * cos_shoulder)
	var wrist := shoulder + direction * distance
	point_bone(upper, shoulder, elbow - shoulder)
	point_bone(lower, elbow, wrist - elbow)
	point_bone(hand, wrist, wrist - elbow)

func point_bone(bone: int, origin: Vector3, direction: Vector3) -> void:
	# Bones run along their local Y axis, as in survivor_visual.gd.
	skeleton.set_bone_global_pose(bone, Transform3D(Basis(Quaternion(Vector3.UP, direction.normalized())), origin))
