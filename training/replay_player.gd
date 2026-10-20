extends Node3D
## Rewatch any recorded training game, with the network that played it.
## Open training/replay.tscn and press F6. It reads recordings from
## training/runs/ (or any folder picked with "Open folder…"); no Python needed.
## Playback only moves the original models to their recorded poses: no game
## script, physics or ragdoll simulation runs.

const GAME := preload("res://game.tscn")
const ENEMY := preload("res://zombie.tscn")
const PLAYER_SCRIPT := preload("res://player___character_body_3d.gd")
const Archive := preload("res://training/replay_archive.gd")
const Capture := preload("res://training/replay_capture.gd")
const BrainView := preload("res://training/brain_view.gd")
const InputsView := preload("res://training/inputs_view.gd")
const TimelineView := preload("res://training/timeline_view.gd")
const ProgressView := preload("res://training/progress_view.gd")
const SETTINGS := "user://replay_viewer.cfg"
const SPEEDS := [0.25, 0.5, 1.0, 2.0, 4.0]
const INK := Color("f0efec")

var archive := Archive.new()
var current := -1
var episode := {}
var frames: Array = []
var actors := {}
var play_time := 0.0
var playing := true
var speed_index := 2
var branch := "actor"
var shown_step := -1
var highlight_row := -1

var world: Node3D
var camera: Camera3D
var overlay: Control
var hud: Label
var health_bar: ProgressBar
var header: Label
var banner: Label
var brain: Control
var keys: Control
var timeline: Control
var progress: Control
var play_button: Button
var speed_button: Button
var clock: Label
var branch_buttons := {}
var folder_dialog: FileDialog

func _ready() -> void:
	var args := {}
	for argument in OS.get_cmdline_user_args():
		var parts := argument.trim_prefix("--").split("=", true, 1)
		args[parts[0]] = parts[1] if parts.size() > 1 else ""
	var settings := ConfigFile.new()
	settings.load(SETTINGS)
	var root: String = args.get("run", settings.get_value("viewer", "folder",
		ProjectSettings.globalize_path("res://training/runs")))
	make_ui()
	var scenery := GAME.instantiate()
	var old_player = scenery.get_node("Player _ CharacterBody3D")
	scenery.remove_child(old_player)
	old_player.free()
	disable_simulation(scenery)
	world.add_child(scenery)
	camera = scenery.get_node("Camera3D")
	camera.make_current()
	if args.has("check"):
		run_check(root)
		return
	var error := archive.open(root)
	progress.source = root
	if error != "":
		show_progress(error)
		return
	var wanted := int(args.get("episode", "0")) - 1
	if wanted < 0:
		wanted = settings.get_value("viewer", "episode", archive.episodes.size()) - 1
	await show_episode(clampi(wanted, 0, archive.episodes.size() - 1))
	if args.has("step"):
		seek(float(args.step))
	if args.has("branch"):
		set_branch(args.branch)
	if args.has("progress"):
		show_progress()
	if args.has("screenshot"):
		playing = false
		for i in 4:
			await RenderingServer.frame_post_draw
		var result := get_viewport().get_texture().get_image().save_png(args.screenshot)
		print("VIEWER_SCREENSHOT ", args.screenshot, " ", result)
		get_tree().quit(result)

# ---------------------------------------------------------------- playback

func disable_simulation(node: Node, stylize := false) -> void:
	if node.get_script() != null:
		node.set_script(null)
	node.process_mode = Node.PROCESS_MODE_DISABLED
	if node is CollisionObject3D:
		node.collision_layer = 0
		node.collision_mask = 0
	if node is AnimationPlayer:
		node.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	if stylize and node is MeshInstance3D:
		for surface in range(node.mesh.get_surface_count()):
			var source = node.get_active_material(surface)
			if source is StandardMaterial3D:
				var material = source.duplicate()
				material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
				node.set_surface_override_material(surface, material)
	for child in node.get_children():
		disable_simulation(child, stylize)

static func transform_from(data: Array) -> Transform3D:
	return Transform3D(Basis(Vector3(data[0], data[1], data[2]),
		Vector3(data[3], data[4], data[5]), Vector3(data[6], data[7], data[8])),
		Vector3(data[9], data[10], data[11]))

static func blend(a: Array, b, t: float) -> Transform3D:
	var from := transform_from(a)
	return from if b == null or t <= 0.0 else from.interpolate_with(transform_from(b), t)

func create_actor(record: Dictionary) -> Dictionary:
	var path: String = record.model
	if not (path.begins_with("res://models/") or path in ["res://gun_model.tscn", "res://bullet.tscn"]):
		push_error("Unsupported replay model: " + path)
		return {}
	var model = load(path).instantiate()
	disable_simulation(model, true)
	world.add_child(model)
	var entry := {"model": model, "animator": model.find_child("AnimationPlayer", true, false),
		"skeleton": Capture.find_skeleton(model)}
	if record.kind in ["hound", "zombie"]:
		var template := ENEMY.instantiate()
		for label in ["StateRing", "ChargeWarning"]:
			var source = template.get_node(label)
			var marker := MeshInstance3D.new()
			marker.mesh = source.mesh
			marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			if source.material_override:
				marker.material_override = source.material_override.duplicate()
			world.add_child(marker)
			entry[label] = marker
		template.free()
	return entry

func clear_actors() -> void:
	for entry in actors.values():
		for key in ["model", "StateRing", "ChargeWarning"]:
			if entry.has(key):
				entry[key].queue_free()
	actors.clear()

func frame_position() -> float:
	# Fractional frame index for the play head, so motion is smooth between samples.
	var last := frames.size() - 1
	if play_time <= frames[0].time:
		return 0.0
	if play_time >= frames[last].time:
		return float(last)
	var low := 0
	var high := last
	while high - low > 1:
		var middle := (low + high) / 2
		if frames[middle].time <= play_time:
			low = middle
		else:
			high = middle
	return low + (play_time - frames[low].time) / maxf(0.0001, frames[high].time - frames[low].time)

func apply_frame() -> void:
	var at := frame_position()
	var index := int(at)
	var t := at - index
	var frame: Dictionary = frames[index]
	var after := {}
	if t > 0.0 and index + 1 < frames.size():
		for record in frames[index + 1].actors:
			after[record.id] = record
	var present := {}
	for record in frame.actors:
		present[record.id] = true
		if not actors.has(record.id):
			actors[record.id] = create_actor(record)
		var entry: Dictionary = actors[record.id]
		if entry.is_empty():
			continue
		var next = after.get(record.id)
		entry.model.global_transform = blend(record.transform, next.transform if next else null, t)
		if entry.skeleton:
			entry.skeleton.reset_bone_poses()
		if entry.animator and record.has("clip") and entry.animator.has_animation(record.clip):
			var clip_time: float = record.clip_time
			if next and next.get("clip") == record.clip and next.clip_time >= clip_time:
				clip_time = lerpf(clip_time, next.clip_time, t)
			entry.animator.play(record.clip)
			entry.animator.seek(clip_time, true)
			entry.animator.advance(0.0)
		if entry.skeleton:
			var next_bones: Dictionary = next.get("bones", {}) if next else {}
			for bone in record.get("bones", {}):
				entry.skeleton.set_bone_pose(int(bone), blend(record.bones[bone], next_bones.get(bone), t))
		if record.kind == "bullet":
			entry.model.get_node("Trail").transform = blend(record.trail, next.trail if next else null, t)
			entry.model.get_node("Trail").visible = record.trail_visible
		if entry.has("StateRing"):
			entry.StateRing.visible = record.get("ring_visible", false)
			entry.ChargeWarning.visible = record.get("warning_visible", false)
			if record.has("ring_transform"):
				entry.StateRing.global_transform = transform_from(record.ring_transform)
				var color: Array = record.ring_color
				entry.StateRing.material_override.albedo_color = Color(color[0], color[1], color[2])
			if record.has("warning_transform"):
				entry.ChargeWarning.global_transform = transform_from(record.warning_transform)
	for identifier in actors.keys():
		if not present.has(identifier):
			for key in ["model", "StateRing", "ChargeWarning"]:
				if actors[identifier].has(key):
					actors[identifier][key].queue_free()
			actors.erase(identifier)
	update_hud(frame, index)
	var decision := mini(index, episode.steps - 1)
	if decision != shown_step:
		shown_step = decision
		update_brain()
	timeline.head = at
	timeline.queue_redraw()
	overlay.queue_redraw()

func update_hud(frame: Dictionary, index: int) -> void:
	var ammo := "RELOADING..." if frame.reloading else "AMMO %d / %d" % [frame.ammo, frame.reserve]
	hud.text = "HEALTH %d / 100 | Kills: %d\n%s\nSurvived: %ds" % [int(frame.health), frame.kills, ammo, int(frame.time)]
	health_bar.value = frame.health
	clock.text = "%s / %s" % [TimelineView.clock(frame.time), TimelineView.clock(frames.back().time)]
	banner.visible = index == frames.size() - 1
	match episode.meta.status:
		"died":
			banner.text = "Died after %s" % TimelineView.clock(frame.time)
		"timeout":
			banner.text = "Survived the whole round"
		_:
			banner.text = "Recording stops here (training was cut off)"

func update_brain() -> void:
	var result := archive.run(episode, shown_step, branch)
	var applied: PackedFloat32Array = episode.actions.slice(shown_step * 7, shown_step * 7 + 7)
	keys.show_action(applied)
	brain.note = integrity_note(result)
	brain.show_result(result, applied)

func integrity_note(result: Dictionary) -> String:
	# Shown only if the saved weights fail to reproduce what the network did live.
	if result.is_empty():
		return "The weights for this moment are missing or damaged."
	var output: PackedFloat32Array = result.layers[3]
	var error := 0.0
	var tolerance := 0.001
	if result.branch == "critic":
		error = absf(output[0] - episode.values[shown_step])
	else:
		tolerance = 0.01  # summed over seven actions, compared against float32 torch
		var weights: PackedFloat32Array = result.net.weights
		var std_at: int = result.net.offsets["actor.log_std"]
		var log_prob := 0.0
		for k in 7:
			var log_std := weights[std_at + k]
			var a: float = episode.raw_actions[shown_step * 7 + k] - output[k]
			log_prob += -a * a / (2.0 * exp(2.0 * log_std)) - log_std - 0.5 * log(TAU)
		error = absf(log_prob - episode.log_probs[shown_step])
	return "" if error < tolerance else "These weights don't reproduce the live decision (off by %.4f)." % error

func seek(frame: float) -> void:
	if frames.is_empty():
		return
	var index := clampi(int(frame), 0, frames.size() - 1)
	play_time = frames[index].time
	apply_frame()

func step(direction: int) -> void:
	set_playing(false)
	seek(round(frame_position()) + direction)

func set_playing(value: bool) -> void:
	if value and frame_position() >= frames.size() - 1:
		play_time = frames[0].time
	playing = value
	play_button.text = "Pause" if playing else "Play"

func _process(delta: float) -> void:
	if not playing or frames.is_empty() or progress.visible:
		return
	play_time += delta * SPEEDS[speed_index]
	if play_time >= frames.back().time:
		play_time = frames.back().time
		set_playing(false)
	apply_frame()

# ---------------------------------------------------------------- episodes

func show_episode(index: int) -> void:
	if index < 0 or index >= archive.episodes.size():
		return
	progress.visible = false
	header.text = "Loading game %d…" % (index + 1)
	await get_tree().process_frame
	await get_tree().process_frame
	var loaded := archive.load_episode(archive.episodes[index])
	if loaded.is_empty():
		header.text = "Game %d could not be read (it may still be being written)." % (index + 1)
		return
	current = index
	episode = loaded
	frames = loaded.frames
	clear_actors()
	shown_step = -1
	var row: Dictionary = loaded.row
	var trained_for := archive.policy_timestep(loaded, archive.policy_id_at(loaded, 0))
	var trained := "untrained network" if trained_for <= 0 else \
		"network trained for %s steps" % ProgressView.steps(trained_for)
	header.text = "Game %d of %d   ·   %s" % [row.number, archive.episodes.size(), trained]
	if archive.sessions[row.session].manifest.get("label", "") != "PPO training":
		header.text += "\n" + archive.sessions[row.session].manifest.label
	timeline.set_episode(frames, loaded.values)
	progress.current = index
	play_time = frames[0].time
	set_playing(true)
	apply_frame()
	var settings := ConfigFile.new()
	settings.load(SETTINGS)
	settings.set_value("viewer", "folder", archive.root)
	settings.set_value("viewer", "episode", index + 1)
	settings.save(SETTINGS)

func show_progress(message := "") -> void:
	progress.rows = archive.episodes
	progress.message = message
	progress.visible = true
	progress.queue_redraw()

func open_folder(path: String) -> void:
	var error := archive.open(path)
	progress.source = path
	if error != "":
		show_progress(error)
		return
	show_progress()

func set_branch(value: String) -> void:
	branch = value
	for key in branch_buttons:
		branch_buttons[key].set_pressed_no_signal(key == value)
	if not episode.is_empty():
		update_brain()

func _unhandled_key_input(event: InputEvent) -> void:
	if not event.is_pressed() or event.is_echo() and event.physical_keycode not in [KEY_LEFT, KEY_RIGHT]:
		return
	if frames.is_empty() and event.physical_keycode != KEY_TAB:
		return
	match event.physical_keycode:
		KEY_TAB:
			if progress.visible and not episode.is_empty():
				progress.visible = false
			else:
				show_progress()
		KEY_SPACE:
			set_playing(not playing)
		KEY_LEFT, KEY_RIGHT:
			var direction := 1 if event.physical_keycode == KEY_RIGHT else -1
			step(direction * (15 if event.shift_pressed else 1))
		KEY_HOME:
			seek(0)
		KEY_END:
			seek(frames.size() - 1)
		KEY_PAGEUP:
			show_episode(current - 1)
		KEY_PAGEDOWN:
			show_episode(current + 1)
		KEY_1:
			set_branch("actor")
		KEY_2:
			set_branch("critic")

# ---------------------------------------------------------------- layout

func make_ui() -> void:
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_title("Zombie Apocalypse · training replays")
		if not Array(OS.get_cmdline_user_args()).any(func(arg): return arg.begins_with("--screenshot")):
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)
	var canvas := CanvasLayer.new()
	add_child(canvas)
	var background := ColorRect.new()
	background.color = Color("111110")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(background)
	var layout := VBoxContainer.new()
	layout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layout.add_theme_constant_override("separation", 0)
	canvas.add_child(layout)
	var columns := HBoxContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 0)
	layout.add_child(columns)

	# The game, as the overhead camera saw it, with the game's own HUD.
	var game_area := Control.new()
	game_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	game_area.size_flags_stretch_ratio = 1.3
	game_area.clip_contents = true
	columns.add_child(game_area)
	var container := SubViewportContainer.new()
	container.stretch = true
	container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	game_area.add_child(container)
	var viewport := SubViewport.new()
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	container.add_child(viewport)
	world = Node3D.new()
	viewport.add_child(world)
	overlay = Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.draw.connect(draw_highlight)
	game_area.add_child(overlay)
	var panel := PanelContainer.new()
	panel.position = Vector2(18, 18)
	panel.custom_minimum_size = Vector2(320, 100)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	game_area.add_child(panel)
	var column := VBoxContainer.new()
	panel.add_child(column)
	hud = Label.new()
	hud.add_theme_font_size_override("font_size", 19)
	column.add_child(hud)
	health_bar = ProgressBar.new()
	health_bar.max_value = 100.0
	health_bar.custom_minimum_size = Vector2(300, 18)
	column.add_child(health_bar)
	header = Label.new()
	header.anchor_right = 1.0
	header.offset_left = 350
	header.offset_right = -18
	header.offset_top = 22
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	header.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	header.add_theme_font_size_override("font_size", 17)
	header.add_theme_constant_override("outline_size", 6)
	header.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	game_area.add_child(header)
	banner = Label.new()
	banner.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.add_theme_font_size_override("font_size", 30)
	banner.add_theme_constant_override("outline_size", 10)
	banner.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	banner.visible = false
	game_area.add_child(banner)
	keys = InputsView.new()
	keys.anchor_top = 1.0
	keys.anchor_bottom = 1.0
	keys.offset_left = 18
	keys.offset_right = 336
	keys.offset_top = -142
	keys.offset_bottom = -18
	game_area.add_child(keys)

	# The network that played it.
	var side := VBoxContainer.new()
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side.add_theme_constant_override("separation", 0)
	columns.add_child(side)
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 6)
	var tabs_margin := MarginContainer.new()
	for edge in ["left", "right", "top"]:
		tabs_margin.add_theme_constant_override("margin_" + edge, 12)
	tabs_margin.add_child(tabs)
	side.add_child(tabs_margin)
	for key in ["actor", "critic"]:
		var button := Button.new()
		button.text = "Policy (what to do)" if key == "actor" else "Value (how it's going)"
		button.toggle_mode = true
		button.button_pressed = key == branch
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(func(): set_branch(key))
		tabs.add_child(button)
		branch_buttons[key] = button
	brain = BrainView.new()
	brain.archive = archive
	brain.player_fields = PLAYER_SCRIPT.PLAYER_OBSERVATION_FIELDS
	brain.enemy_fields = PLAYER_SCRIPT.ENEMY_OBSERVATION_FIELDS
	brain.size_flags_vertical = Control.SIZE_EXPAND_FILL
	brain.input_hovered.connect(func(row: int):
		highlight_row = row
		overlay.queue_redraw())
	side.add_child(brain)

	# Transport and timeline.
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	var bar_margin := MarginContainer.new()
	for edge in ["left", "right", "top", "bottom"]:
		bar_margin.add_theme_constant_override("margin_" + edge, 10)
	bar_margin.add_child(bar)
	layout.add_child(bar_margin)
	var previous := Button.new()
	previous.text = "Previous game"
	previous.pressed.connect(func(): show_episode(current - 1))
	bar.add_child(previous)
	play_button = Button.new()
	play_button.text = "Pause"
	play_button.custom_minimum_size.x = 70
	play_button.pressed.connect(func(): set_playing(not playing))
	bar.add_child(play_button)
	var following := Button.new()
	following.text = "Next game"
	following.pressed.connect(func(): show_episode(current + 1))
	bar.add_child(following)
	speed_button = Button.new()
	speed_button.text = "1x"
	speed_button.custom_minimum_size.x = 52
	speed_button.pressed.connect(func():
		speed_index = (speed_index + 1) % SPEEDS.size()
		speed_button.text = str(SPEEDS[speed_index]) + "x")
	bar.add_child(speed_button)
	clock = Label.new()
	clock.custom_minimum_size.x = 110
	clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bar.add_child(clock)
	timeline = TimelineView.new()
	timeline.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	timeline.seek.connect(func(frame: float):
		set_playing(false)
		seek(frame))
	bar.add_child(timeline)
	var all := Button.new()
	all.text = "All games"
	all.pressed.connect(func(): show_progress())
	bar.add_child(all)
	for button in [previous, play_button, following, speed_button, all]:
		button.focus_mode = Control.FOCUS_NONE

	progress = ProgressView.new()
	progress.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	progress.visible = false
	progress.chosen.connect(show_episode)
	progress.open_folder.connect(func(): folder_dialog.popup_centered_ratio(0.6))
	canvas.add_child(progress)
	folder_dialog = FileDialog.new()
	folder_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	folder_dialog.access = FileDialog.ACCESS_FILESYSTEM
	folder_dialog.title = "Folder with downloaded training runs"
	folder_dialog.dir_selected.connect(open_folder)
	canvas.add_child(folder_dialog)

func draw_highlight() -> void:
	# Circles whatever the hovered row of "What it sees" describes.
	if highlight_row < 0 or frames.is_empty() or camera == null:
		return
	var index := int(frame_position())
	var player: Array = frames[index].player_position
	var target := Vector3(player[0], player[1], player[2])
	if highlight_row > 0:
		var base := index * 586 + 28 + (highlight_row - 1) * 31
		if episode.observations[base] == 0.0:
			return
		target += Vector3(episode.observations[base + 1] * 32.0,
			episode.observations[base + 2] * 64.0, episode.observations[base + 3] * 20.0)
	var point := camera.unproject_position(target + Vector3.UP * 0.6)
	overlay.draw_arc(point, 22.0, 0, TAU, 40, INK, 2.0, true)
	var label := "You" if highlight_row == 0 else "Enemy %d" % highlight_row
	overlay.draw_string(overlay.get_theme_default_font(), point + Vector2(26, 6), label,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 15, INK)

# ---------------------------------------------------------------- check

func run_check(root: String) -> void:
	# Headless verification used by smoke_test_replays.py.
	var error := archive.open(root)
	if error != "":
		push_error(error)
		get_tree().quit(1)
		return
	var decisions := 0
	var worst := 0.0
	for index in archive.episodes.size():
		var loaded := archive.load_episode(archive.episodes[index])
		if loaded.is_empty():
			push_error("Could not read " + archive.episodes[index].id)
			get_tree().quit(1)
			return
		episode = loaded
		frames = loaded.frames
		clear_actors()
		for step_index in loaded.steps:
			var result := archive.run(loaded, step_index, "critic")
			worst = maxf(worst, absf(result.layers[3][0] - loaded.values[step_index]))
			decisions += 1
		for actor_step in [0, loaded.steps - 1]:
			shown_step = actor_step
			if integrity_note(archive.run(loaded, actor_step, "actor")) != "":
				push_error("Actor mismatch at %s step %d" % [loaded.row.id, actor_step])
				get_tree().quit(1)
				return
		shown_step = -1
		for frame_index in frames.size():
			play_time = lerpf(frames[frame_index].time, frames[mini(frame_index + 1, frames.size() - 1)].time, 0.5)
			apply_frame()
	if worst > 0.001:
		push_error("Value mismatch %.6f" % worst)
		get_tree().quit(1)
		return
	# Drive the interface the way a person would, so drawing/input code runs too.
	await show_episode(0)
	for branch_name in ["critic", "actor"]:
		set_branch(branch_name)
		await get_tree().process_frame
		for point in [Vector2(46, 120), Vector2(60, 200), Vector2(brain.size.x * 0.5, 200),
				Vector2(brain.size.x - 150, brain.size.y * 0.4)]:
			var motion := InputEventMouseMotion.new()
			motion.position = point
			brain._gui_input(motion)
			var click := InputEventMouseButton.new()
			click.position = point
			click.button_index = MOUSE_BUTTON_LEFT
			click.pressed = true
			brain._gui_input(click)
			await get_tree().process_frame
	seek(frames.size() * 0.5)
	highlight_row = 1
	overlay.queue_redraw()
	show_progress()
	for metric in ["kills", "reward", "seconds"]:
		progress.set_metric(metric)
		var hover := InputEventMouseMotion.new()
		hover.position = progress._point(archive.episodes[0], progress._range())
		progress._gui_input(hover)
		await get_tree().process_frame
	await show_episode(archive.episodes.size() - 1)
	await get_tree().process_frame
	print("REPLAY_CHECK_OK episodes=%d decisions=%d worst_value_error=%.7f actors=%d" % [
		archive.episodes.size(), decisions, worst, actors.size()])
	get_tree().quit()
