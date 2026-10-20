extends RefCounted
## Read-only samples. Playback applies these poses; it never reruns game physics.

static func transform_data(value: Transform3D) -> Array:
	return [value.basis.x.x, value.basis.x.y, value.basis.x.z,
		value.basis.y.x, value.basis.y.y, value.basis.y.z,
		value.basis.z.x, value.basis.z.y, value.basis.z.z,
		value.origin.x, value.origin.y, value.origin.z]

static func find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found := find_skeleton(child)
		if found:
			return found
	return null

static func visual(model: Node3D, kind: String, animator: AnimationPlayer = null, ragdoll := false) -> Dictionary:
	var result := {"id": str(model.get_instance_id()), "kind": kind,
		"model": model.scene_file_path, "transform": transform_data(model.global_transform)}
	if animator and animator.is_playing():
		result["clip"] = animator.current_animation
		result["clip_time"] = animator.current_animation_position
	var skeleton := find_skeleton(model)
	if skeleton:
		var bones := {}
		for index in range(skeleton.get_bone_count()):
			# Animated bodies use the clip; preserve arm overrides and ragdoll poses.
			if ragdoll or (kind == "player" and skeleton.get_bone_name(index) in ["RightArm", "RightForeArm", "LeftArm", "LeftForeArm"]):
				bones[str(index)] = transform_data(skeleton.get_bone_pose(index))
		result["bones"] = bones
	return result

static func capture(session: Node, game: Node, player: Node3D, elapsed: float) -> Dictionary:
	var actors: Array = []
	var character = player.get_node("CharacterVisual")
	actors.append(visual(character.model, "player", character.animator))
	actors.append(visual(player.gun_model, "gun"))
	for enemy in session.get_tree().get_nodes_in_group("zombies"):
		if not is_instance_valid(enemy) or enemy.is_queued_for_deletion() or is_instance_valid(enemy.ragdoll):
			continue
		if enemy.visuals.get_child_count() == 0:
			continue
		var actor := visual(enemy.visuals.get_child(0), "hound" if enemy.is_hound else "zombie", enemy.animator)
		actor["state"] = "climbing" if enemy.climbing else enemy.state
		actor["health"] = enemy.health
		actor["heading"] = [enemy.heading.x, enemy.heading.z]
		actor["warning_visible"] = enemy.warning.visible
		actor["warning_transform"] = transform_data(enemy.warning.global_transform)
		actor["ring_visible"] = enemy.marker.visible
		actor["ring_transform"] = transform_data(enemy.marker.global_transform)
		actor["ring_color"] = [enemy.marker.material_override.albedo_color.r,
			enemy.marker.material_override.albedo_color.g, enemy.marker.material_override.albedo_color.b]
		actors.append(actor)
	for rag in session.get_tree().get_nodes_in_group("enemy_ragdolls"):
		if not is_instance_valid(rag.visual_root) or rag.is_queued_for_deletion():
			continue
		var model = rag.visual_root.get_child(0)
		var actor := visual(model, "hound" if "hound" in model.scene_file_path else "zombie", null, true)
		actor["state"] = "corpse" if rag.is_corpse else "fallen"
		actors.append(actor)
	for child in session.get_children():
		if child.scene_file_path == "res://bullet.tscn" and not child.is_queued_for_deletion():
			var actor := visual(child, "bullet")
			actor["trail"] = transform_data(child.trail.transform)
			actor["trail_visible"] = child.trail.visible
			actors.append(actor)
	return {"time": elapsed, "actors": actors,
		"player_position": [player.position.x, player.position.y, player.position.z],
		"health": player.health, "ammo": player.ammo_in_magazine,
		"reserve": player.reserve_ammo, "kills": game.kills,
		"reloading": player.reloading, "dashing": player.dash_time_left > 0,
		"player_fields": player.PLAYER_OBSERVATION_FIELDS,
		"enemy_fields": player.ENEMY_OBSERVATION_FIELDS}
