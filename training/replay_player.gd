extends Node3D
## Visual playback only. Every source script/collision is disabled before adding
## the scenery/models, so playback cannot change combat or simulate ragdolls.
const GAME = preload("res://game.tscn")
const ENEMY = preload("res://zombie.tscn")
var frames: Array = []
var actors := {}
var index := 0
var playing := true
var speed := 1.0
var play_time := 0.0
var hud: Label
var slider: HSlider
var play_button: Button
var updating_slider := false
var episode_name := ""
var world: Node3D
var brain: Control
var decisions: Array = []
var policies: Dictionary = {}
var screenshot_path := ""
var recording_label := ""
var python_bin := ""
var archive_path := ""
var replay_file := ""
var available_episodes: Array = []
var loading_pid := -1
var loading_episode := ""

func _ready() -> void:
	var file_path := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--replay-file="):
			file_path = argument.trim_prefix("--replay-file=")
		elif argument.begins_with("--screenshot="):
			screenshot_path = argument.trim_prefix("--screenshot=")
		elif argument.begins_with("--step="):
			index = argument.trim_prefix("--step=").to_int()
		elif argument.begins_with("--python-bin="):
			python_bin = argument.trim_prefix("--python-bin=")
		elif argument.begins_with("--archive-path="):
			archive_path = argument.trim_prefix("--archive-path=")
	if not FileAccess.file_exists(file_path):
		push_error("Launch this viewer with training/replay_game.py")
		get_tree().quit(1)
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(file_path))
	if not data is Dictionary or not data.has("frames") or data.frames.is_empty():
		push_error("Invalid replay file")
		get_tree().quit(1)
		return
	frames = data.frames
	replay_file = file_path
	available_episodes = data.get("available_episodes", [])
	episode_name = data.id
	recording_label = data.get("label", "RECORDED TRAINING DATA")
	decisions = data.get("decisions", [])
	policies = data.get("policies", {})
	index = clampi(index, 0, frames.size() - 1)
	play_time = frames[index].time
	make_ui()
	brain.player_fields = frames[0].player_fields
	brain.enemy_fields = frames[0].enemy_fields
	brain.policies = policies
	var scenery := GAME.instantiate()
	var old_player = scenery.get_node("Player _ CharacterBody3D")
	scenery.remove_child(old_player)
	old_player.free()
	disable_simulation(scenery)
	world.add_child(scenery)
	scenery.get_node("Camera3D").make_current()
	apply_frame()
	if "--replay-switch-check" in OS.get_cmdline_user_args():
		if episode_name == available_episodes[0].id:
			load_episode(1)
		else:
			print("EPISODE_SWITCH_OK ", episode_name)
			get_tree().quit()
		return
	# Optional bounded headless verification, used by the replay integration test.
	if "--replay-check" in OS.get_cmdline_user_args():
		for frame_index in range(frames.size()):
			index = frame_index
			apply_frame()
		step_frame(-1)
		slider.value = 0
		assert(index == 0)
		find_child("critic", true, false).pressed.emit()
		assert(brain.branch == "critic")
		find_child("actor", true, false).pressed.emit()
		assert(brain.branch == "actor")
		print("REPLAY_CHECK_OK frames=", frames.size(), " actors=", actors.size())
		get_tree().quit()
	elif not screenshot_path.is_empty():
		playing = false
		play_button.text = "Play"
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var error := get_viewport().get_texture().get_image().save_png(screenshot_path)
		print("VIEWER_SCREENSHOT ", screenshot_path, " result=", error)
		get_tree().quit(error)

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

func transform_from(data: Array) -> Transform3D:
	return Transform3D(Basis(Vector3(data[0], data[1], data[2]),
		Vector3(data[3], data[4], data[5]), Vector3(data[6], data[7], data[8])),
		Vector3(data[9], data[10], data[11]))

func create_actor(record: Dictionary) -> Dictionary:
	var path: String = record.model
	if not (path.begins_with("res://models/") or path in ["res://gun_model.tscn", "res://bullet.tscn"]):
		push_error("Unsupported replay model: " + path)
		return {}
	var model = load(path).instantiate()
	disable_simulation(model, true)
	world.add_child(model)
	var entry := {"model": model, "animator": model.find_child("AnimationPlayer", true, false),
		"skeleton": load("res://training/replay_capture.gd").find_skeleton(model)}
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

func apply_frame() -> void:
	var frame: Dictionary = frames[index]
	brain.decision = decisions[index] if index < decisions.size() else {}
	brain.queue_redraw()
	var present := {}
	for record in frame.actors:
		present[record.id] = true
		if not actors.has(record.id):
			actors[record.id] = create_actor(record)
		var entry: Dictionary = actors[record.id]
		if entry.is_empty():
			continue
		entry.model.global_transform = transform_from(record.transform)
		if entry.skeleton:
			entry.skeleton.reset_bone_poses()
		if entry.animator and record.has("clip") and entry.animator.has_animation(record.clip):
			entry.animator.play(record.clip)
			entry.animator.seek(record.clip_time, true)
			entry.animator.advance(0.0)
		if entry.skeleton:
			for bone in record.get("bones", {}):
				entry.skeleton.set_bone_pose(int(bone), transform_from(record.bones[bone]))
		if record.kind == "bullet":
			entry.model.get_node("Trail").transform = transform_from(record.trail)
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
					actors[identifier][key].free()
			actors.erase(identifier)
	hud.text = "RECORDED PLAYBACK | %s | %.2f / %.2fs\nHEALTH %d | AMMO %d / %d | KILLS %d\nSpace: pause | Arrows: step | Slider: seek | No live physics" % [
		episode_name, frame.time, frames.back().time, frame.health, frame.ammo, frame.reserve, frame.kills]
	updating_slider = true
	slider.value = index
	updating_slider = false

func make_ui() -> void:
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_title("Zombie Apocalypse | Recorded gameplay + neural activity")
		DisplayServer.window_set_size(Vector2i(1560, 940))
	var canvas := CanvasLayer.new()
	add_child(canvas)
	var background := ColorRect.new()
	background.color = Color("171c16")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(background)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 18)
	canvas.add_child(margin)
	var theme := Theme.new()
	var system_font := SystemFont.new()
	system_font.font_names = PackedStringArray(["Consolas", "Courier New"])
	theme.default_font = system_font
	theme.default_font_size = 14
	var button_style := StyleBoxFlat.new()
	button_style.bg_color = Color("30382a")
	button_style.border_color = Color("686e50")
	button_style.set_border_width_all(1)
	button_style.content_margin_left = 12
	button_style.content_margin_right = 12
	button_style.content_margin_top = 8
	button_style.content_margin_bottom = 8
	theme.set_stylebox("normal", "Button", button_style)
	theme.set_stylebox("hover", "Button", button_style)
	theme.set_color("font_color", "Button", Color("e7b655"))
	margin.theme = theme
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 14)
	margin.add_child(layout)
	var title := Label.new()
	title.text = "ZOMBIE APOCALYPSE / THE SURVIVOR'S BRAIN"
	title.add_theme_font_size_override("font_size", 25)
	title.add_theme_color_override("font_color", Color("e7b655"))
	layout.add_child(title)
	var subtitle := Label.new()
	subtitle.text = recording_label + " / RECORDED STATES + MATCHING NETWORK WEIGHTS / NO VIDEO"
	subtitle.add_theme_font_size_override("font_size", 12)
	subtitle.add_theme_color_override("font_color", Color("a5ab92"))
	layout.add_child(subtitle)
	var columns := HBoxContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 18)
	layout.add_child(columns)
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 1.25
	columns.add_child(left)
	var game_title := Label.new()
	game_title.text = "01 / RECORDED GAMEPLAY                         ORIGINAL GAME ASSETS"
	game_title.add_theme_color_override("font_color", Color("bdbd9f"))
	game_title.add_theme_font_size_override("font_size", 12)
	left.add_child(game_title)
	var viewport_container := SubViewportContainer.new()
	viewport_container.stretch = true
	viewport_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(viewport_container)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(800, 650)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport_container.add_child(viewport)
	world = Node3D.new()
	viewport.add_child(world)
	hud = Label.new()
	hud.add_theme_font_size_override("font_size", 15)
	hud.add_theme_color_override("font_color", Color("dedbc2"))
	left.add_child(hud)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_stretch_ratio = 1.0
	columns.add_child(right)
	var tabs := HBoxContainer.new()
	right.add_child(tabs)
	for branch in ["actor", "critic"]:
		var button := Button.new()
		button.name = branch
		button.text = "ACTOR / ACTIONS" if branch == "actor" else "CRITIC / VALUE"
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(func(): brain.set_branch(branch))
		tabs.add_child(button)
	brain = load("res://training/brain_view.gd").new()
	brain.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(brain)
	var controls := HBoxContainer.new()
	layout.add_child(controls)
	if not available_episodes.is_empty() and not python_bin.is_empty():
		var picker := OptionButton.new()
		picker.custom_minimum_size.x = 300
		for entry in available_episodes:
			picker.add_item("%s / %.1fs / %d kills" % [entry.id, entry.seconds, entry.kills])
			if entry.id == episode_name:
				picker.selected = picker.item_count - 1
		picker.item_selected.connect(load_episode)
		controls.add_child(picker)
	play_button = Button.new()
	play_button.text = "Pause"
	play_button.pressed.connect(toggle_play)
	controls.add_child(play_button)
	for direction in [-1, 1]:
		var step_button := Button.new()
		step_button.text = "< Step" if direction < 0 else "Step >"
		step_button.pressed.connect(func(): step_frame(direction))
		controls.add_child(step_button)
	var speeds := OptionButton.new()
	for value in [0.25, 0.5, 1.0, 2.0, 4.0]:
		speeds.add_item(str(value) + "x")
	speeds.selected = 2
	speeds.item_selected.connect(func(selected_index: int): speed = [0.25, 0.5, 1.0, 2.0, 4.0][selected_index])
	controls.add_child(speeds)
	slider = HSlider.new()
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.max_value = frames.size() - 1
	slider.step = 1
	slider.value_changed.connect(func(value: float):
		if not updating_slider:
			index = int(value)
			play_time = frames[index].time
			apply_frame())
	controls.add_child(slider)

func step_frame(direction: int) -> void:
	playing = false
	play_button.text = "Play"
	index = clampi(index + direction, 0, frames.size() - 1)
	play_time = frames[index].time
	apply_frame()

func toggle_play() -> void:
	if index == frames.size() - 1:
		index = 0
		play_time = 0.0
		apply_frame()
	playing = not playing
	play_button.text = "Pause" if playing else "Play"

func _process(delta: float) -> void:
	if loading_pid > 0:
		if not OS.is_process_running(loading_pid):
			loading_pid = -1
			var loaded = JSON.parse_string(FileAccess.get_file_as_string(replay_file))
			if loaded is Dictionary and loaded.get("id", "") == loading_episode:
				install_episode(loaded)
				if "--replay-switch-check" in OS.get_cmdline_user_args():
					print("EPISODE_SWITCH_OK ", episode_name)
					get_tree().quit()
			else:
				hud.text = "Could not load episode. Close this viewer and launch replay_game.py again."
		return
	if not playing or frames.is_empty():
		return
	play_time += delta * speed
	var previous := index
	while index + 1 < frames.size() and frames[index + 1].time <= play_time:
		index += 1
	if index != previous:
		apply_frame()
	if index == frames.size() - 1:
		playing = false
		play_button.text = "Play"

func _unhandled_key_input(event: InputEvent) -> void:
	if not event.is_pressed() or event.is_echo():
		return
	if event.physical_keycode == KEY_SPACE:
		toggle_play()
	elif event.physical_keycode in [KEY_LEFT, KEY_RIGHT]:
		step_frame(1 if event.physical_keycode == KEY_RIGHT else -1)

func load_episode(selected_index: int) -> void:
	var identifier: String = available_episodes[selected_index].id
	if identifier == episode_name or loading_pid > 0:
		return
	playing = false
	play_button.text = "Play"
	loading_episode = identifier
	hud.text = "Loading %s and its matching network weights..." % identifier
	loading_pid = OS.create_process(python_bin, PackedStringArray([
		ProjectSettings.globalize_path("res://training/replay_game.py"),
		"--run", archive_path, "--episode", identifier, "--export-only", replay_file]), false)
	if loading_pid < 0:
		hud.text = "Could not start Python to prepare the selected episode."

func install_episode(data: Dictionary) -> void:
	# Keep static scenery alive while replacing only recorded actors and brain data.
	for entry in actors.values():
		for key in ["model", "StateRing", "ChargeWarning"]:
			if entry.has(key):
				entry[key].free()
	actors.clear()
	frames = data.frames
	episode_name = data.id
	decisions = data.decisions
	policies = data.policies
	brain.policies = policies
	brain.player_fields = frames[0].player_fields
	brain.enemy_fields = frames[0].enemy_fields
	index = 0
	play_time = 0.0
	updating_slider = true
	slider.max_value = frames.size() - 1
	updating_slider = false
	apply_frame()

func _exit_tree() -> void:
	if loading_pid > 0 and OS.is_process_running(loading_pid):
		OS.kill(loading_pid)
