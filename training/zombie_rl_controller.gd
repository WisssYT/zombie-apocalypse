extends "res://addons/godot_rl_agents/controller/ai_controller_3d.gd"

var game: Node3D
var elapsed := 0.0
var episode_limit := 60.0
var started := false
var finished := false
var terminated := false
var truncated := false
var terminal_observation: Array[float] = []
var previous_health := 100.0
var previous_kills := 0
var episode_return := 0.0
var replay_enabled := false
const REPLAY_CAPTURE = preload("res://training/replay_capture.gd")

func enable_replay() -> bool:
	replay_enabled = true
	return true

func bind_episode(world: Node3D, player: Node3D, time_limit: float) -> void:
	game = world
	init(player)
	elapsed = 0.0
	episode_limit = time_limit
	started = false
	finished = false
	terminated = false
	truncated = false
	done = false
	needs_reset = false
	n_steps = 0
	reward = 0.0
	episode_return = 0.0
	terminal_observation.clear()
	previous_health = _player.health
	previous_kills = game.kills

func _physics_process(delta: float) -> void:
	# Overrides the addon's generic step limit; use simulation seconds instead.
	if not started or finished or not is_instance_valid(_player):
		return
	n_steps += 1
	elapsed += delta
	var damage_taken: float = maxf(0.0, previous_health - _player.health)
	var new_kills: int = maxi(0, game.kills - previous_kills)
	# Initial reward, to be tuned after observing learned behavior.
	var step_reward := 0.05 * delta + 2.0 * new_kills - 0.02 * damage_taken
	previous_health = _player.health
	previous_kills = game.kills
	terminated = _player.dead
	truncated = not terminated and elapsed + 0.000001 >= episode_limit
	if terminated:
		step_reward -= 2.0
	reward += step_reward
	episode_return += step_reward
	if terminated or truncated:
		finished = true
		done = true
		terminal_observation = _player.get_observation()
		get_parent().freeze_episode()

func get_obs() -> Dictionary:
	return {"obs": terminal_observation if finished else _player.get_observation()}

func get_reward() -> float:
	return reward

func get_action_space() -> Dictionary:
	# move X/Z, mouse X/Z, shoot, reload, dash. One continuous Box for SB3.
	return {"controls": {"size": 7, "action_type": "continuous"}}

func set_action(action) -> void:
	if finished:
		return
	var values: Array = action.get("controls", [])
	if values.size() != 7:
		push_error("Expected seven action values")
		return
	for value in values:
		if not is_finite(float(value)):
			push_error("Action values must be finite")
			return
	_player.ai_move = Vector2(values[0], values[1]).limit_length(1.0)
	_player.ai_mouse = Vector2(values[2], values[3]).limit_length(1.0)
	_player.ai_shoot = float(values[4]) > 0.0
	_player.ai_reload_requested = float(values[5]) > 0.0
	_player.ai_dash_requested = float(values[6]) > 0.0
	started = true
	game.process_mode = Node.PROCESS_MODE_INHERIT

func get_info() -> Dictionary:
	var info := {
		"terminated": terminated, "truncated": truncated,
		"elapsed": elapsed, "kills": game.kills, "health": _player.health,
		"ammo": _player.ammo_in_magazine, "reserve": _player.reserve_ammo,
		"reloading": _player.reloading, "dashing": _player.dash_time_left > 0,
		"episode_return": episode_return, "episode_index": get_parent().episode_index,
		"collisions": game.stats.collision, "hound_knockdowns": game.stats.hound_knockdown,
		"tripped": game.stats.tripped, "fell_off": game.stats.fell_off,
		"position": [_player.position.x, _player.position.y, _player.position.z]
	}
	if replay_enabled:
		info["replay"] = REPLAY_CAPTURE.capture(get_parent(), game, _player, elapsed)
	return info

func reset() -> void:
	get_parent().reset_episode.call_deferred()

func reset_sequence() -> bool:
	# Called by Python reset(seed=...) to repeat the seed's initial round.
	get_parent().episode_index = -1
	return true
