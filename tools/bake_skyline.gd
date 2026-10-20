extends SceneTree
## Bakes the fog skyline: flat "cards" showing the real tower models, for the distant city.
## Run from the project folder, in this order:
##   godot --path . -s tools/bake_skyline.gd -- atlas     (renders the towers; needs a display)
##   godot --headless --path . --import
##   godot --headless --path . -s tools/bake_skyline.gd -- meshes
## The cards sit on render layer 11, which only the first-person camera draws: the overhead
## camera magnifies them too much, and the real towers already fill its view.

const OUT_DIR := "res://models/skyline/"
const MODELS := ["building_01", "building_02", "building_05", "building_06", "building_07"]
const CELL := Vector2i(256, 512)
# Each cell shows the top CARD_HEIGHT metres of a tower; the rest is lost in the height fog.
const CARD_HEIGHT := 120.0
const ROWS := 2

var mode := ""
var step := 0
var waits := 0
var jobs: Array = []
var atlas: Image
var viewport: SubViewport
var camera: Camera3D
var light: DirectionalLight3D
var current_model: Node3D

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	mode = args[0] if args.size() > 0 else ""
	if not mode in ["atlas", "meshes"]:
		push_error("Pass -- atlas or -- meshes")
		quit(1)

func _process(_delta: float) -> bool:
	step += 1
	if step == 1:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
		if mode == "atlas":
			start_atlas()
		else:
			build_meshes()
		return false
	if mode == "atlas":
		advance_atlas()
	return false

# --- Game data -------------------------------------------------------------

func tower_scale(model: String) -> Vector3:
	# The scale the city uses for this model, so the art matches the real towers.
	var city: Node = load("res://apocalyptic_city.tscn").instantiate()
	var result := Vector3(0.44, 0.85, 0.44)
	for child in city.get_children():
		if child.scene_file_path.ends_with(model + ".glb"):
			result = child.scale
			break
	city.free()
	return result

# --- Atlas -----------------------------------------------------------------

func start_atlas() -> void:
	atlas = Image.create(CELL.x * MODELS.size(), CELL.y * ROWS, false, Image.FORMAT_RGBA8)
	viewport = SubViewport.new()
	viewport.size = CELL
	viewport.transparent_bg = true
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_CLEAR_COLOR
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.65, 0.59, 0.46)
	environment.ambient_light_energy = 0.24
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	viewport.add_child(world_environment)
	light = DirectionalLight3D.new()
	light.light_color = Color(1, 0.9, 0.73)
	light.light_energy = 1.1
	light.shadow_enabled = true
	light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	light.directional_shadow_max_distance = 600.0
	viewport.add_child(light)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = CARD_HEIGHT
	camera.near = 1.0
	camera.far = 1500.0
	viewport.add_child(camera)
	for column in MODELS.size():
		# Two sides of each tower, seen almost level and lit from the front-left.
		for row in ROWS:
			var view := Basis.from_euler(Vector3(deg_to_rad(-10.0), deg_to_rad(row * 65.0 + 20.0), 0.0))
			var sun := view * Basis.from_euler(Vector3(deg_to_rad(-40.0), deg_to_rad(-35.0), 0.0))
			jobs.append([column, row, view, sun])

func advance_atlas() -> void:
	if waits > 0:
		waits -= 1
		if waits == 0:
			var job: Array = jobs.pop_front()
			var image := viewport.get_texture().get_image()
			image.convert(Image.FORMAT_RGBA8)
			atlas.blit_rect(image, Rect2i(Vector2i.ZERO, CELL), Vector2i(job[0] * CELL.x, job[1] * CELL.y))
			current_model.queue_free()
			current_model = null
		return
	if jobs.is_empty():
		var path := ProjectSettings.globalize_path(OUT_DIR + "skyline_atlas.png")
		atlas.save_png(path)
		print("Saved ", path)
		quit()
		return
	var job: Array = jobs[0]
	var model_name: String = MODELS[job[0]]
	current_model = load("res://models/apocalyptic_city/%s.glb" % model_name).instantiate()
	current_model.scale = tower_scale(model_name)
	viewport.add_child(current_model)
	frame_camera(job[2], job[3])
	# A few frames let the shadow map settle before the capture.
	waits = 4

func model_corners(model: Node3D) -> Array:
	var corners := []
	for mesh in model.find_children("*", "MeshInstance3D", true, false):
		var box: AABB = mesh.global_transform * mesh.get_aabb()
		for i in 8:
			corners.append(box.get_endpoint(i))
	return corners

func frame_camera(view: Basis, sun: Basis) -> void:
	# Put the tower's top edge at the top of the cell, centred left to right.
	var inverse := view.inverse()
	var top := -INF
	var left := INF
	var right := -INF
	for corner in model_corners(current_model):
		var local: Vector3 = inverse * corner
		top = maxf(top, local.y)
		left = minf(left, local.x)
		right = maxf(right, local.x)
	var centre := Vector3((left + right) * 0.5, top + 2.0 - CARD_HEIGHT * 0.5, 700.0)
	camera.transform = Transform3D(view, view * centre)
	light.transform = Transform3D(sun, Vector3.ZERO)

# --- Meshes ----------------------------------------------------------------

func card_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	material.alpha_scissor_threshold = 0.5
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_texture = load(OUT_DIR + "skyline_atlas.png")
	return material

func cell_uv(column: int, row: int, mirrored: bool) -> Rect2:
	var size := Vector2(1.0 / MODELS.size(), 1.0 / ROWS)
	var rect := Rect2(Vector2(column, row) * size, size)
	if mirrored:
		rect.position.x += rect.size.x
		rect.size.x = -rect.size.x
	return rect

func add_card(st: SurfaceTool, centre: Vector3, right: Vector3, up: Vector3, uv: Rect2) -> void:
	# right and up are half-extents. Two triangles per card.
	var corners := [centre - right + up, centre + right + up, centre + right - up, centre - right - up]
	var uvs := [uv.position, uv.position + Vector2(uv.size.x, 0), uv.end, uv.position + Vector2(0, uv.size.y)]
	for i in [0, 1, 2, 0, 2, 3]:
		st.set_uv(uvs[i])
		st.add_vertex(corners[i])

func tower_boxes(city: Node3D) -> Array:
	var boxes := []
	for child in city.get_children():
		if child.name.begins_with("RuinedTower") or child.name == "ArenaBuilding":
			for mesh in child.find_children("*", "MeshInstance3D", true, false):
				boxes.append(mesh.global_transform * mesh.get_aabb())
	return boxes

func build_meshes() -> void:
	var city: Node3D = load("res://apocalyptic_city.tscn").instantiate()
	root.add_child(city)
	var boxes := tower_boxes(city)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1337
	var material := card_material()
	var aspect := float(CELL.x) / CELL.y

	# Ring: cards stand around the arena facing its centre, between and beyond the real towers.
	var ring := SurfaceTool.new()
	ring.begin(Mesh.PRIMITIVE_TRIANGLES)
	var placed: Array[Vector2] = []
	var ring_count := 0
	var attempts := 0
	while ring_count < 36 and attempts < 4000:
		attempts += 1
		var angle := rng.randf() * TAU
		var radius := rng.randf_range(110.0, 175.0)
		var spot := Vector2(cos(angle), sin(angle)) * radius
		var scale := rng.randf_range(0.8, 1.25)
		var half_width := CARD_HEIGHT * aspect * 0.5 * scale
		var clear := true
		for box in boxes:
			var nearest := Vector2(clampf(spot.x, box.position.x, box.end.x), clampf(spot.y, box.position.z, box.end.z))
			if nearest.distance_to(spot) < half_width + 6.0:
				clear = false
				break
		for other in placed:
			if other.distance_to(spot) < 22.0:
				clear = false
				break
		if not clear:
			continue
		placed.append(spot)
		var top := rng.randf_range(-15.0, 65.0)
		var half_height := CARD_HEIGHT * 0.5 * scale
		var facing := -Vector3(spot.x, 0, spot.y).normalized()
		var right := Vector3.UP.cross(facing).normalized() * half_width
		add_card(ring, Vector3(spot.x, top - half_height, spot.y), right, Vector3.UP * half_height,
			cell_uv(rng.randi_range(0, MODELS.size() - 1), rng.randi_range(0, ROWS - 1), rng.randf() < 0.5))
		ring_count += 1
	ring.set_material(material)
	ResourceSaver.save(ring.commit(), OUT_DIR + "skyline_ring.tres")
	print("Ring cards: ", ring_count)

	city.free()
	quit()
