extends Node3D
## A small jointed skeleton, created only while an enemy tumbles or dies.
## Bodies only collide with the arena's dedicated world layer, never one another.
const MAX_ACTIVE := 6
var skeleton: Skeleton3D
var visual_root: Node3D
var bodies: Dictionary = {}
var bone_offsets: Dictionary = {}
var is_corpse := false
var age := 0.0

static func find_skeleton(node: Node) -> Skeleton3D:
 if node is Skeleton3D:
  return node
 for child in node.get_children():
  var found := find_skeleton(child)
  if found:
   return found
 return null

static func create(visual: Node3D, hound: bool, launch: Vector3, corpse: bool) -> Node3D:
 var rig := find_skeleton(visual)
 if not rig:
  return null
 var active := visual.get_tree().get_nodes_in_group("enemy_ragdolls")
 if active.size() >= MAX_ACTIVE:
  for old in active:
   if old.is_corpse:
    old.queue_free()
    active.erase(old)
    break
  if active.size() >= MAX_ACTIVE:
   return null
 var result = load("res://enemy_ragdoll.gd").new()
 visual.get_tree().current_scene.add_child(result)
 result.add_to_group("enemy_ragdolls")
 result.skeleton = rig
 result.visual_root = visual
 result.is_corpse = corpse
 visual.reparent(result, true)
 result.build(hound, launch)
 return result

func build(hound: bool, launch: Vector3) -> void:
 # name, endpoint bone, radius, mass. Hands, paws and jaw follow their parent.
 var segments: Array
 if hound:
  segments = [
   ["Hips", "Spine", 0.13, 3.5], ["Spine", "Chest", 0.13, 3.0],
   ["Chest", "Neck", 0.14, 3.5], ["Head", "", 0.10, 1.5],
   ["BackLeftUpper", "BackLeftLower", 0.055, 0.8],
   ["BackLeftLower", "BackLeftHock", 0.045, 0.6],
   ["BackLeftHock", "BackLeftPaw", 0.04, 0.4],
   ["BackRightUpper", "BackRightLower", 0.055, 0.8],
   ["BackRightLower", "BackRightHock", 0.045, 0.6],
   ["BackRightHock", "BackRightPaw", 0.04, 0.4],
   ["FrontLeftUpper", "FrontLeftLower", 0.055, 0.8],
   ["FrontLeftLower", "FrontLeftPaw", 0.045, 0.6],
   ["FrontRightUpper", "FrontRightLower", 0.055, 0.8],
   ["FrontRightLower", "FrontRightPaw", 0.045, 0.6],
   ["Tail1", "Tail3", 0.035, 0.25]]
 else:
  segments = [
   ["Hips", "Spine", 0.14, 4.0], ["Spine", "Chest", 0.13, 3.0],
   ["Chest", "Neck", 0.15, 4.0], ["Head", "", 0.105, 1.5],
   ["LeftUpperArm", "LeftLowerArm", 0.06, 0.75],
   ["LeftLowerArm", "LeftHand", 0.05, 0.5],
   ["RightUpperArm", "RightLowerArm", 0.06, 0.75],
   ["RightLowerArm", "RightHand", 0.05, 0.5],
   ["LeftUpperLeg", "LeftLowerLeg", 0.075, 1.5],
   ["LeftLowerLeg", "LeftFoot", 0.06, 1.0],
   ["RightUpperLeg", "RightLowerLeg", 0.075, 1.5],
   ["RightLowerLeg", "RightFoot", 0.06, 1.0]]
 var material := PhysicsMaterial.new()
 material.friction = 0.85
 material.bounce = 0.0
 var scale_factor := skeleton.global_basis.get_scale().x
 # The feet act as the pivot: horizontal launch topples the body, little of it slides it.
 var pivot := visual_root.global_position
 var horizontal := Vector3(launch.x, 0.0, launch.z)
 var lift := Vector3(0.0, maxf(launch.y, 0.0), 0.0)
 var push := horizontal * 0.25
 var hip_height := 0.9 * scale_factor
 var spin := Vector3.ZERO
 if horizontal.length_squared() > 0.01:
  spin = Vector3.UP.cross(horizontal.normalized()) * minf(horizontal.length() * 0.75 / hip_height, 5.0)
 for segment in segments:
  var index := skeleton.find_bone(segment[0])
  if index < 0:
   continue
  var rest := skeleton.get_bone_global_rest(index)
  var pose := skeleton.global_transform * skeleton.get_bone_global_pose(index)
  var end_index := skeleton.find_bone(segment[1]) if segment[1] != "" else -1
  var local_tip: Vector3
  if end_index >= 0:
   local_tip = rest.affine_inverse() * skeleton.get_bone_global_rest(end_index).origin
  else:
   var head_direction := Vector3(0, 0, 0.24) if hound else Vector3(0, 0.22, 0)
   local_tip = rest.basis.inverse() * head_direction
  var end := pose * local_tip
  var direction := end - pose.origin
  var body := RigidBody3D.new()
  body.name = "Limb_" + str(segment[0])
  body.mass = segment[3]
  body.collision_layer = 0
  body.collision_mask = 8
  body.linear_damp = 0.3
  body.angular_damp = 2.0
  body.physics_material_override = material
  var shape := CapsuleShape3D.new()
  shape.radius = float(segment[2]) * scale_factor
  shape.height = maxf(direction.length() * 0.9, shape.radius * 2.0)
  var collider := CollisionShape3D.new()
  collider.shape = shape
  body.add_child(collider)
  add_child(body)
  var axis := direction.normalized() if direction.length() > 0.001 else Vector3.UP
  body.global_transform = Transform3D(Basis(Quaternion(Vector3.UP, axis)), pose.origin.lerp(end, 0.5))
  # One shared rotation about the feet: the body tips over instead of every limb spinning alone.
  body.angular_velocity = spin
  body.linear_velocity = lift + push + spin.cross(body.global_position - pivot)
  bodies[index] = body
  bone_offsets[index] = body.global_transform.affine_inverse() * pose
 # Each limb is jointed to its nearest simulated parent bone.
 for index in bodies:
  var parent_index := skeleton.get_bone_parent(index)
  while parent_index >= 0 and not bodies.has(parent_index):
   parent_index = skeleton.get_bone_parent(parent_index)
  if parent_index < 0:
   continue
  # Cone joints keep limbs floppy but stop heads and knees from spinning freely.
  var joint := ConeTwistJoint3D.new()
  var limits := joint_limits(skeleton.get_bone_name(index))
  joint.set_param(ConeTwistJoint3D.PARAM_SWING_SPAN, limits.x)
  joint.set_param(ConeTwistJoint3D.PARAM_TWIST_SPAN, limits.y)
  joint.set_param(ConeTwistJoint3D.PARAM_SOFTNESS, 0.9)
  joint.set_param(ConeTwistJoint3D.PARAM_RELAXATION, 1.0)
  add_child(joint)
  # The cone's axis (local X) points along the child limb as it was when the body fell.
  var limb_axis: Vector3 = bodies[index].global_basis.y.normalized()
  joint.global_transform = Transform3D(Basis(Quaternion(Vector3.RIGHT, limb_axis)), (skeleton.global_transform * skeleton.get_bone_global_pose(index)).origin)
  joint.node_a = joint.get_path_to(bodies[parent_index])
  joint.node_b = joint.get_path_to(bodies[index])
  joint.exclude_nodes_from_collision = true

static func joint_limits(bone: String) -> Vector2:
 # x = swing cone, y = twist, both in radians.
 if bone.ends_with("UpperArm"):
  return Vector2(1.3, 0.7)
 if bone.ends_with("UpperLeg") or bone.ends_with("Upper"):
  return Vector2(0.9, 0.35)
 if bone.ends_with("Lower") or bone.ends_with("LowerArm") or bone.ends_with("LowerLeg") or bone.ends_with("Hock"):
  return Vector2(1.1, 0.15)
 if bone == "Head":
  return Vector2(0.6, 0.5)
 if bone.begins_with("Tail"):
  return Vector2(0.8, 0.3)
 return Vector2(0.45, 0.25)

func _physics_process(delta: float) -> void:
 age += delta
 if not is_instance_valid(skeleton):
  queue_free()
  return
 var inverse := skeleton.global_transform.affine_inverse()
 # Skeleton order is parent before child; untouched terminal bones follow naturally.
 for index in range(skeleton.get_bone_count()):
  if bodies.has(index):
   skeleton.set_bone_global_pose(index, inverse * bodies[index].global_transform * bone_offsets[index])
 if is_corpse and (age > 7.0 or center().y < -35.0):
  queue_free()

func center() -> Vector3:
 var hips := skeleton.find_bone("Hips")
 return bodies[hips].global_position if bodies.has(hips) else global_position

func kick(launch: Vector3) -> void:
 for body in bodies.values():
  body.sleeping = false
  body.linear_velocity += launch

func release_visual(parent: Node3D, original_transform: Transform3D) -> void:
 set_physics_process(false)
 visual_root.reparent(parent, false)
 visual_root.transform = original_transform
 skeleton.reset_bone_poses()
 queue_free()
