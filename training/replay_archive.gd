extends RefCounted
## Reads the recordings written by recording.py and reruns the saved network.
## Pure Godot: the viewing PC needs no Python, torch or GPU.

const POLICY_CACHE := 6
const OBSERVATION_SCHEMA := 3  # recordings from older layouts can't be labelled correctly

var root := ""
var sessions: Array = []   # [{path, manifest, policies: {id: timestep}}]
var episodes: Array = []   # summary rows from every session, in training order
var _policies := {}
var _policy_order: Array = []

func open(path: String) -> String:
	root = path
	sessions.clear()
	episodes.clear()
	_policies.clear()
	_policy_order.clear()
	var found: Array = []
	_find_sessions(path, found, 0)
	found.sort()
	for session_path in found:
		var manifest = _read_json(session_path.path_join("manifest.json"))
		if not manifest is Dictionary or int(manifest.get("format", 0)) != 2 \
				or int(manifest.get("observation_schema", 0)) != OBSERVATION_SCHEMA:
			continue
		var timesteps := {}
		var listed = _read_json(session_path.path_join("policies.json"))
		for entry in (listed if listed is Array else []):
			timesteps[entry.id] = entry.timestep
		var session := {"path": session_path, "manifest": manifest, "policies": timesteps}
		sessions.append(session)
		var index = _read_json(session_path.path_join("index.json"))
		for entry in (index if index is Array else []):
			entry["session"] = sessions.size() - 1
			entry["mode"] = manifest.get("mode", "training")
			entry["number"] = episodes.size() + 1
			episodes.append(entry)
	if episodes.is_empty():
		return "No recorded episodes in %s" % path
	return ""

func _find_sessions(path: String, found: Array, depth: int) -> void:
	if FileAccess.file_exists(path.path_join("manifest.json")) and DirAccess.dir_exists_absolute(path.path_join("episodes")):
		found.append(path)
		return
	if depth > 5:
		return
	var directory := DirAccess.open(path)
	if directory == null:
		return
	for child in directory.get_directories():
		if not child.begins_with("."):
			_find_sessions(path.path_join(child), found, depth + 1)

func _read_json(path: String):
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))

func _gunzip(path: String) -> PackedByteArray:
	var bytes := FileAccess.get_file_as_bytes(path)
	return bytes.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP) if not bytes.is_empty() else bytes

## Loads one episode: world frames plus flat float arrays sliced per name.
func load_episode(row: Dictionary) -> Dictionary:
	var session: Dictionary = sessions[row.session]
	var base: String = session.path.path_join("episodes").path_join(row.id)
	var meta = JSON.parse_string(_gunzip(base + ".json.gz").get_string_from_utf8())
	var flat := _gunzip(base + ".bin.gz").to_float32_array()
	if not meta is Dictionary:
		return {}
	var episode := {"row": row, "meta": meta, "frames": meta.frames, "steps": int(meta.steps),
		"session": row.session}
	var offset := 0
	for entry in meta.arrays:
		var count := 1
		for dimension in entry.shape:
			count *= int(dimension)
		episode[entry.name] = flat.slice(offset, offset + count)
		offset += count
	if offset != flat.size() or meta.frames.size() != episode.steps + 1:
		return {}
	return episode

func policy_id_at(episode: Dictionary, step: int) -> String:
	var result := ""
	for run in episode.meta.policy_runs:
		if int(run[0]) <= step:
			result = run[1]
	return result

func policy_timestep(episode: Dictionary, policy_id: String) -> int:
	return int(sessions[episode.session].policies.get(policy_id, -1))

## Exploration noise the policy used for this attempt: mean action std, or 0
## for evaluation games, which always take the network's most likely action.
func noise(episode: Dictionary) -> float:
	if episode.row.mode == "evaluation":
		return 0.0
	var net := policy(episode.session, policy_id_at(episode, 0))
	if net.is_empty():
		return -1.0
	var at: int = net.offsets["actor.log_std"]
	var total := 0.0
	for k in 7:
		total += exp(net.weights[at + k])
	return total / 7.0

func policy(session_index: int, policy_id: String) -> Dictionary:
	var key := "%d/%s" % [session_index, policy_id]
	if _policies.has(key):
		return _policies[key]
	var session: Dictionary = sessions[session_index]
	var bytes := FileAccess.get_file_as_bytes(session.path.path_join("policies").path_join(policy_id + ".bin"))
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(bytes)
	if hashing.finish().hex_encode() != policy_id:
		push_error("Weights %s fail their checksum" % policy_id.substr(0, 12))
		return {}
	var weights := bytes.to_float32_array()
	var offsets := {}
	var offset := 0
	for layer in session.manifest.policy_layout:
		var count := 1
		for dimension in layer.shape:
			count *= int(dimension)
		offsets[layer.name] = offset
		offset += count
	if offset != weights.size():
		push_error("Weight file does not match its manifest")
		return {}
	var result := {"weights": weights, "offsets": offsets}
	_policies[key] = result
	_policy_order.append(key)
	if _policy_order.size() > POLICY_CACHE:
		_policies.erase(_policy_order.pop_front())
	return result

## One forward pass of "actor" or "critic" for the observation at `step`.
## Also keeps, for every neuron, the two inputs that pushed it hardest.
func run(episode: Dictionary, step: int, branch: String) -> Dictionary:
	var net := policy(episode.session, policy_id_at(episode, step))
	if net.is_empty():
		return {}
	var w: PackedFloat32Array = net.weights
	var at: Dictionary = net.offsets
	var size: int = sessions[episode.session].manifest.observation_size
	var x: PackedFloat32Array = episode.observations.slice(step * size, step * size + size)
	var first := _dense(w, at[branch + ".0.weight"], at[branch + ".0.bias"], x, size, 128)
	var h1: PackedFloat32Array = first[0]
	for o in 128:
		h1[o] = tanh(h1[o])
	var second := _dense(w, at[branch + ".1.weight"], at[branch + ".1.bias"], h1, 128, 128)
	var h2: PackedFloat32Array = second[0]
	for o in 128:
		h2[o] = tanh(h2[o])
	var outputs := 7 if branch == "actor" else 1
	var third := _dense(w, at[branch + ".out.weight"], at[branch + ".out.bias"], h2, 128, outputs)
	return {"branch": branch, "step": step, "inputs": x, "layers": [x, h1, h2, third[0]],
		"drivers": [first[1], second[1], third[1]], "net": net}

## Weight from input `i` of `layer` (0 = observation -> hidden 1) to neuron `o`.
func weight(result: Dictionary, layer: int, i: int, o: int) -> float:
	var names := [".0.weight", ".1.weight", ".out.weight"]
	var outputs := 128 if layer < 2 else (7 if result.branch == "actor" else 1)
	return result.net.weights[result.net.offsets[result.branch + names[layer]] + i * outputs + o]

func _dense(w: PackedFloat32Array, w_at: int, b_at: int, x: PackedFloat32Array, n_in: int, n_out: int) -> Array:
	var out := w.slice(b_at, b_at + n_out)
	var best := PackedFloat32Array()
	best.resize(n_out * 2)
	var drivers := PackedInt32Array()
	drivers.resize(n_out * 2)
	drivers.fill(-1)
	for i in n_in:
		var v := x[i]
		if v == 0.0:
			continue
		var base := w_at + i * n_out
		for o in n_out:
			var c := w[base + o] * v
			out[o] += c
			var a := absf(c)
			if a > best[o * 2 + 1]:
				if a > best[o * 2]:
					best[o * 2 + 1] = best[o * 2]
					drivers[o * 2 + 1] = drivers[o * 2]
					best[o * 2] = a
					drivers[o * 2] = i
				else:
					best[o * 2 + 1] = a
					drivers[o * 2 + 1] = i
	return [out, drivers]
