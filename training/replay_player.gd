extends Node3D
## Rewatch any recorded training attempt, with the network that played it.
## Open training/replay.tscn and press F6. It reads recordings from
## training/runs/ (or any folder picked on the attempts screen); no Python needed.
## Playback only moves the original models to their recorded poses: no game
## script, physics or ragdoll simulation runs.

const GAME := preload("res://game.tscn")
const ENEMY := preload("res://zombie.tscn")
const PLAYER_SCRIPT := preload("res://player___character_body_3d.gd")
const Archive := preload("res://training/replay_archive.gd")
const Capture := preload("res://training/replay_capture.gd")
const Style := preload("res://training/replay_style.gd")
const FpsBody := preload("res://training/replay_fps_body.gd")
const BrainView := preload("res://training/brain_view.gd")
const InputsView := preload("res://training/inputs_view.gd")
const RunPanel := preload("res://training/run_panel.gd")
const TimelineView := preload("res://training/timeline_view.gd")
const ProgressView := preload("res://training/progress_view.gd")
const SETTINGS := "user://replay_viewer.cfg"
# Movie Maker sizes the video from the project's window settings at startup and
# ignores --resolution, so a video render gets them from a one-off override.cfg
# that the renderer deletes as soon as it has started. The frame rate is passed as
# --fixed-fps, which (unlike the movie_writer/fps setting) it does honour.
const VIDEO_OVERRIDE := "res://override.cfg"
const VIDEO_OVERRIDE_TEXT := """; Written by the replay viewer for one video render; deleted when it starts.
[display]
window/size/viewport_width=1280
window/size/viewport_height=720
window/size/window_width_override=1280
window/size/window_height_override=720
"""
const VIDEO_FPS := 30
const SPEEDS := [0.25, 0.5, 1.0, 2.0, 4.0]
const SPEED_LABELS := [".25X", ".5X", "1X", "2X", "4X"]
# Same layers as the game: the body is hidden from the first-person camera,
# the first-person arms and rifle are hidden from the overhead camera.
const BODY_LAYER := 2
const FIRST_PERSON_LAYER := 1 << 10
const FPS_CULL_MASK := 1048573
const EYE_HEIGHT := 0.65
# Observation schema v3 (AI_OBSERVATIONS.md); _ready() checks it against the player script.
const PLAYER_VALUES := 32
const ENEMY_VALUES := 31
const OBS := PLAYER_VALUES + 18 * ENEMY_VALUES
const AIM_X := 11
const AIM_Z := 12
const RELOAD_LEFT := 13
const CURSOR_X := 28
const CURSOR_Z := 29
const GAP := 2.0

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
var best_loaded_for := ""
var video_mode := false
var video_hold := 0.0
var video_pid := -1
var video_path := ""

var world: Node3D
var camera: Camera3D
var fps_camera: Camera3D
var fps_body: Node3D
var fps_pivot: Node3D
var top_feed: Control
var fps_feed: Control
var overlay: Control
var hud: Label
var health_bar: ProgressBar
var brain: Control
var keys: Control
var run: Control
var timeline: Control
var progress: Control
var folder_dialog: FileDialog

func _ready() -> void:
	assert(PLAYER_SCRIPT.PLAYER_OBSERVATION_FIELDS.size() == PLAYER_VALUES
		and PLAYER_SCRIPT.ENEMY_OBSERVATION_FIELDS.size() == ENEMY_VALUES
		and PLAYER_SCRIPT.MAX_OBSERVED_ENEMIES == 18, "Observation layout changed; update the replay viewer")
	var args := {}
	for argument in OS.get_cmdline_user_args():
		var parts := argument.trim_prefix("--").split("=", true, 1)
		args[parts[0]] = parts[1] if parts.size() > 1 else ""
	remove_video_override()
	var settings := ConfigFile.new()
	settings.load(SETTINGS)
	var root: String = args.get("run", settings.get_value("viewer", "folder",
		ProjectSettings.globalize_path("res://training/runs")))
	make_ui()
	var scenery := GAME.instantiate()
	var old_player = scenery.get_node("Player _ CharacterBody3D")
	var pivot: Node3D = old_player.get_node("WeaponPivot")
	_release(pivot)
	old_player.remove_child(pivot)
	scenery.remove_child(old_player)
	old_player.free()
	disable_simulation(scenery)
	world.add_child(scenery)
	camera = scenery.get_node("Camera3D")
	camera.make_current()
	make_first_person(pivot)
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
	if args.has("select"):
		var parts: PackedStringArray = args.select.split(",")
		brain.selected = Vector2i(parts[0].to_int(), parts[1].to_int())
	if args.has("hover-row"):
		highlight_row = args["hover-row"].to_int()
	if args.has("progress"):
		show_progress()
	if args.has("save-video"):
		# Command-line export: start the renderer for this attempt and leave.
		save_video()
		get_tree().quit(0 if video_pid > 0 else 1)
		return
	if args.has("video"):
		# Plays this attempt once at normal speed under Godot's Movie Maker, then closes.
		video_mode = true
		seek(0)
		set_playing(true)
	if args.has("screenshot"):
		set_playing(false)
		for i in 4:
			await RenderingServer.frame_post_draw
		var result := get_viewport().get_texture().get_image().save_png(args.screenshot)
		print("VIEWER_SCREENSHOT ", args.screenshot, " ", result)
		get_tree().quit(result)

func _release(node: Node) -> void:
	node.owner = null
	for child in node.get_children():
		_release(child)

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

static func set_layers(node: Node, layers: int) -> void:
	if node is VisualInstance3D:
		node.layers = layers
	for child in node.get_children():
		set_layers(child, layers)

static func transform_from(data: Array) -> Transform3D:
	return Transform3D(Basis(Vector3(data[0], data[1], data[2]),
		Vector3(data[3], data[4], data[5]), Vector3(data[6], data[7], data[8])),
		Vector3(data[9], data[10], data[11]))

static func blend(a: Array, b, t: float) -> Transform3D:
	var from := transform_from(a)
	return from if b == null or t <= 0.0 else from.interpolate_with(transform_from(b), t)

func make_first_person(pivot: Node3D) -> void:
	# The game's own weapon pivot: rifle plus first_person_arms.gd, which poses
	# the arms on the rifle from the stand-in body's fields.
	fps_body = FpsBody.new()
	fps_feed.get_child(0).add_child(fps_body)
	for child in pivot.get_children():
		if child.name != "FirstPersonArms":
			disable_simulation(child, true)
	set_layers(pivot.get_node("GunModel"), FIRST_PERSON_LAYER)
	fps_body.add_child(pivot)
	fps_pivot = pivot

func create_actor(record: Dictionary) -> Dictionary:
	var path: String = record.model
	if not (path.begins_with("res://models/") or path in ["res://gun_model.tscn", "res://bullet.tscn"]):
		push_error("Unsupported replay model: " + path)
		return {}
	var model = load(path).instantiate()
	disable_simulation(model, true)
	if record.kind in ["player", "gun"]:
		set_layers(model, BODY_LAYER)
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
	update_first_person(index, t)
	update_hud(frame)
	var decision := mini(index, episode.steps - 1)
	if decision != shown_step:
		shown_step = decision
		update_brain()
	run.now = lerpf(frame.time, frames[mini(index + 1, frames.size() - 1)].time, t)
	var stats: Dictionary = frame.get("stats", {})
	run.collisions = stats.get("collision", 0) + stats.get("hound_knockdown", 0)
	run.fell_off = stats.get("fell_off", 0)
	run.dodged = stats.get("charge_dodged", 0)
	run.queue_redraw()
	brain.head = at
	brain.queue_redraw()
	timeline.head = at
	timeline.queue_redraw()
	overlay.queue_redraw()

func update_first_person(index: int, t: float) -> void:
	# Eye height above the player, looking along the weapon's actual aim, as in
	# the game's first-person mode (AI aim has no pitch).
	var next := mini(index + 1, frames.size() - 1)
	var a: Array = frames[index].player_position
	var b: Array = frames[next].player_position
	var eye := Vector3(a[0], a[1], a[2]).lerp(Vector3(b[0], b[1], b[2]), t) + Vector3.UP * EYE_HEIGHT
	var obs: PackedFloat32Array = episode.observations
	var yaw := lerp_angle(atan2(-obs[index * OBS + AIM_X], -obs[index * OBS + AIM_Z]),
		atan2(-obs[next * OBS + AIM_X], -obs[next * OBS + AIM_Z]), t)
	fps_camera.global_transform = Transform3D(Basis(Vector3.UP, yaw), eye)
	fps_pivot.global_transform = Transform3D(
		fps_camera.global_basis * Basis(Vector3.BACK, PLAYER_SCRIPT.FPS_WEAPON_CANT),
		fps_camera.global_transform * PLAYER_SCRIPT.FPS_WEAPON_OFFSET)
	fps_body.reloading = frames[index].reloading
	fps_body.reload_time_left = obs[index * OBS + RELOAD_LEFT]
	fps_body.dead = frames[index].health <= 0.0

func update_hud(frame: Dictionary) -> void:
	# The game's own HUD, as the player saw it.
	var ammo := "RELOADING..." if frame.reloading else "AMMO %d / %d" % [frame.ammo, frame.reserve]
	hud.text = "HEALTH %d / 100 | Kills: %d\n%s\nSurvived: %ds" % [int(frame.health), frame.kills, ammo, int(frame.time)]
	health_bar.value = frame.health

func update_brain() -> void:
	var result := archive.run(episode, shown_step, branch)
	var applied: PackedFloat32Array = episode.actions.slice(shown_step * 7, shown_step * 7 + 7)
	var obs: PackedFloat32Array = episode.observations
	keys.show_action(applied, Vector2(obs[shown_step * OBS + AIM_X], obs[shown_step * OBS + AIM_Z]))
	brain.note = integrity_note(result)
	brain.show_result(result, applied)

func integrity_note(result: Dictionary) -> String:
	# Shown only if the saved weights fail to reproduce what the network did live.
	if result.is_empty():
		return "WEIGHTS MISSING OR DAMAGED"
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
	return "" if error < tolerance else "WEIGHTS DON'T MATCH THIS RECORDING (OFF BY %.4f)" % error

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
	if value and not frames.is_empty() and frame_position() >= frames.size() - 1:
		play_time = frames[0].time
	playing = value
	timeline.playing = value
	timeline.queue_redraw()

func _process(delta: float) -> void:
	if video_pid > 0 and not OS.is_process_running(video_pid):
		video_pid = -1
		timeline.message = "SAVED " + video_path.get_file().to_upper()
		timeline.queue_redraw()
	if video_mode and not playing:
		video_hold += delta
		if video_hold > 1.5:
			get_tree().quit()
		return
	if not playing or frames.is_empty() or progress.visible:
		return
	play_time += delta * SPEEDS[speed_index]
	if play_time >= frames.back().time:
		play_time = frames.back().time
		set_playing(false)
	apply_frame()

# ---------------------------------------------------------------- attempts

static func kill_times(episode_frames: Array) -> Array:
	var times := []
	for i in range(1, episode_frames.size()):
		for kill in int(episode_frames[i].kills) - int(episode_frames[i - 1].kills):
			times.append(float(episode_frames[i].time))
	return times

func load_best() -> void:
	# Best attempt so far = most kills, then longest survival. Its kill times
	# are the splits every other attempt is compared against.
	if best_loaded_for == archive.root:
		return
	best_loaded_for = archive.root
	run.best = []
	run.best_attempt = 0
	var best := {}
	for row in archive.episodes:
		if row.status in ["died", "timeout"] and int(row.kills) > 0 and (best.is_empty()
				or row.kills > best.kills or row.kills == best.kills and row.seconds > best.seconds):
			best = row
	if best.is_empty():
		return
	var loaded := archive.load_episode(best)
	if not loaded.is_empty():
		run.best = kill_times(loaded.frames)
		run.best_attempt = best.number

func show_episode(index: int) -> void:
	if index < 0 or index >= archive.episodes.size():
		return
	progress.visible = false
	await get_tree().process_frame
	load_best()
	var loaded := archive.load_episode(archive.episodes[index])
	if loaded.is_empty():
		return
	current = index
	episode = loaded
	frames = loaded.frames
	clear_actors()
	shown_step = -1
	var row: Dictionary = loaded.row
	run.attempt = row.number
	run.attempts = archive.episodes.size()
	run.trained = archive.policy_timestep(loaded, archive.policy_id_at(loaded, 0))
	var label: String = archive.sessions[row.session].manifest.get("label", "")
	run.note = "EVALUATION" if row.mode == "evaluation" else "" if label == "PPO training" else "TEST RUN"
	run.noise = archive.noise(loaded)
	run.status = loaded.meta.status
	run.end_time = frames.back().time
	run.kills = kill_times(frames)
	brain.values = loaded.values
	timeline.set_episode(frames)
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
	show_progress(error)

func set_branch(value: String) -> void:
	branch = value
	if not episode.is_empty():
		update_brain()

func on_bar(control: String) -> void:
	match control:
		"previous":
			show_episode(current - 1)
		"next":
			show_episode(current + 1)
		"play":
			set_playing(not playing)
		"speed":
			speed_index = (speed_index + 1) % SPEEDS.size()
			timeline.speed = SPEED_LABELS[speed_index]
			timeline.queue_redraw()
		"attempts":
			show_progress()
		"video":
			save_video()

## Renders the current attempt to training/videos/ in a separate Godot process,
## using Movie Maker so every frame is captured: 1280x720 at a steady 30 fps.
func save_video() -> void:
	if current < 0 or video_pid > 0:
		return
	var folder := ProjectSettings.globalize_path("res://training/videos")
	DirAccess.make_dir_recursive_absolute(folder)
	FileAccess.open(folder.path_join(".gdignore"), FileAccess.WRITE)
	video_path = folder.path_join("attempt-%d.avi" % archive.episodes[current].number)
	var override := FileAccess.open(VIDEO_OVERRIDE, FileAccess.WRITE)
	override.store_string(VIDEO_OVERRIDE_TEXT)
	override.close()
	video_pid = OS.create_process(OS.get_executable_path(), PackedStringArray([
		"--path", ProjectSettings.globalize_path("res://"), "--write-movie", video_path,
		"--fixed-fps", str(VIDEO_FPS), "res://training/replay.tscn", "--", "--run=" + archive.root,
		"--episode=%d" % (current + 1), "--video"]))
	if video_pid < 0:
		remove_video_override()
	timeline.message = "SAVING VIDEO..." if video_pid > 0 else "COULD NOT START GODOT"
	timeline.queue_redraw()

static func remove_video_override() -> void:
	# Only ever removes the file save_video() wrote, never one made by hand.
	if FileAccess.file_exists(VIDEO_OVERRIDE) \
			and FileAccess.get_file_as_string(VIDEO_OVERRIDE).begins_with(VIDEO_OVERRIDE_TEXT.get_slice("\n", 0)):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(VIDEO_OVERRIDE))

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

func make_feed(share_with: SubViewport = null) -> SubViewportContainer:
	var container := SubViewportContainer.new()
	container.stretch = true
	container.clip_contents = true
	var viewport := SubViewport.new()
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	if share_with:
		viewport.world_3d = share_with.find_world_3d()
	else:
		viewport.own_world_3d = true
	container.add_child(viewport)
	return container

func make_ui() -> void:
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_title("Zombie Apocalypse - replays")
		if not Array(OS.get_cmdline_user_args()).any(func(arg): return arg.begins_with("--screenshot") or arg == "--video"):
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)
	var canvas := CanvasLayer.new()
	add_child(canvas)
	var screen := Control.new()
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(screen)
	var background := ColorRect.new()
	background.color = Color("050505")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen.add_child(background)

	# Overhead feed with the game's own HUD and the input display.
	top_feed = make_feed()
	screen.add_child(top_feed)
	world = Node3D.new()
	top_feed.get_child(0).add_child(world)
	overlay = Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.draw.connect(draw_highlight)
	top_feed.add_child(overlay)
	var panel := PanelContainer.new()
	panel.position = Vector2(18, 18)
	panel.custom_minimum_size = Vector2(320, 100)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_feed.add_child(panel)
	var column := VBoxContainer.new()
	panel.add_child(column)
	hud = Label.new()
	hud.add_theme_font_size_override("font_size", 19)
	column.add_child(hud)
	health_bar = ProgressBar.new()
	health_bar.max_value = 100.0
	health_bar.custom_minimum_size = Vector2(300, 18)
	column.add_child(health_bar)
	keys = InputsView.new()
	keys.anchor_top = 1.0
	keys.anchor_bottom = 1.0
	keys.offset_left = 12
	keys.offset_right = 12 + 340
	keys.offset_top = -12 - 124
	keys.offset_bottom = -12
	top_feed.add_child(keys)

	# First-person feed, same world, the game's FPS camera settings and crosshair.
	fps_feed = make_feed(top_feed.get_child(0))
	screen.add_child(fps_feed)
	fps_camera = Camera3D.new()
	fps_camera.fov = 85.0
	fps_camera.near = 0.04
	fps_camera.cull_mask = FPS_CULL_MASK
	fps_feed.get_child(0).add_child(fps_camera)
	fps_camera.current = true
	var crosshair := Label.new()
	crosshair.text = "+"
	crosshair.add_theme_font_size_override("font_size", 24)
	crosshair.add_theme_color_override("font_shadow_color", Color.BLACK)
	crosshair.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	crosshair.grow_horizontal = Control.GROW_DIRECTION_BOTH
	crosshair.grow_vertical = Control.GROW_DIRECTION_BOTH
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fps_feed.add_child(crosshair)

	run = RunPanel.new()
	screen.add_child(run)
	brain = BrainView.new()
	brain.archive = archive
	brain.player_fields = PLAYER_SCRIPT.PLAYER_OBSERVATION_FIELDS
	brain.enemy_fields = PLAYER_SCRIPT.ENEMY_OBSERVATION_FIELDS
	brain.input_hovered.connect(func(row: int):
		highlight_row = row
		overlay.queue_redraw())
	brain.branch_chosen.connect(set_branch)
	screen.add_child(brain)
	timeline = TimelineView.new()
	timeline.seek.connect(func(frame: float):
		set_playing(false)
		seek(frame))
	timeline.pressed.connect(on_bar)
	screen.add_child(timeline)

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
	screen.resized.connect(arrange.bind(screen))
	arrange(screen)

func arrange(screen: Control) -> void:
	# Split-screen layout: overhead feed on the left; first-person feed, run
	# timer/splits and the network stacked on the right; transport along the bottom.
	var w := screen.size.x
	var h := screen.size.y
	var bar_h := 34.0
	var side := clampf(roundf(w * 0.32), 360.0, 580.0)
	var left := w - side
	var fps_h := roundf(side * 9.0 / 16.0)
	var run_h: float = run.custom_minimum_size.y
	_place(top_feed, Rect2(0, 0, left - GAP, h - bar_h - GAP))
	_place(fps_feed, Rect2(left, 0, side, fps_h))
	_place(run, Rect2(left, fps_h + GAP, side, run_h))
	_place(brain, Rect2(left, fps_h + run_h + GAP * 2, side, h - bar_h - fps_h - run_h - GAP * 3))
	_place(timeline, Rect2(0, h - bar_h, w, bar_h))

static func _place(control: Control, rect: Rect2) -> void:
	control.position = rect.position
	control.size = rect.size

func draw_highlight() -> void:
	if frames.is_empty() or camera == null:
		return
	draw_cursor()
	# Brackets whatever the hovered input row describes, on the overhead feed.
	if highlight_row < 0:
		return
	var index := int(frame_position())
	var player: Array = frames[index].player_position
	var target := Vector3(player[0], player[1], player[2])
	if highlight_row > 0:
		var base := index * OBS + PLAYER_VALUES + (highlight_row - 1) * ENEMY_VALUES
		if episode.observations[base] == 0.0:
			return
		target += Vector3(episode.observations[base + 1] * 32.0,
			episode.observations[base + 2] * 64.0, episode.observations[base + 3] * 20.0)
	var point := camera.unproject_position(target + Vector3.UP * 0.6).round()
	var box := Rect2(point - Vector2(16, 16), Vector2(32, 32))
	for corner in [box.position, Vector2(box.end.x, box.position.y), box.end, Vector2(box.position.x, box.end.y)]:
		var inward: Vector2 = (box.get_center() - corner).sign() * 8.0
		overlay.draw_line(corner, corner + Vector2(inward.x, 0), Style.GOLD, 2.0)
		overlay.draw_line(corner, corner + Vector2(0, inward.y), Style.GOLD, 2.0)
	Style.text(overlay, box.position + Vector2(box.size.x + 8, 14), "YOU" if highlight_row == 0 else "ENEMY %d" % highlight_row,
		16, Style.GOLD, true)

func draw_cursor() -> void:
	# The AI's mouse pointer, where a player's cursor would be on screen.
	var at := frame_position()
	var index := int(at)
	var next := mini(index + 1, frames.size() - 1)
	var obs: PackedFloat32Array = episode.observations
	var points := []
	for i in [index, next]:
		var player: Array = frames[i].player_position
		points.append(Vector3(player[0] + obs[i * OBS + CURSOR_X] * 32.0, player[1],
			player[2] + obs[i * OBS + CURSOR_Z] * 20.0))
	var tip := camera.unproject_position(points[0].lerp(points[1], at - index)).round()
	var arrow := PackedVector2Array([Vector2(0, 0), Vector2(0, 17), Vector2(4, 13), Vector2(7, 20),
		Vector2(10, 19), Vector2(7, 12), Vector2(12, 12)])
	var outline := PackedVector2Array()
	for point in arrow:
		outline.append(tip + point)
	overlay.draw_colored_polygon(outline, Color.WHITE)
	outline.append(outline[0])
	overlay.draw_polyline(outline, Color.BLACK, 1.0)

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
		for point in [Vector2(20, 60), Vector2(40, 100), Vector2(brain.size.x * 0.55, 90),
				Vector2(brain.size.x - 40, 80), Vector2(80, 16)]:
			var motion := InputEventMouseMotion.new()
			motion.position = point
			brain._gui_input(motion)
			var click := InputEventMouseButton.new()
			click.position = point
			click.button_index = MOUSE_BUTTON_LEFT
			click.pressed = true
			brain._gui_input(click)
			await get_tree().process_frame
	for control in ["speed", "play", "play", "next", "previous"]:
		on_bar(control)
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
