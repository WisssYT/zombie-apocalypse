extends Node3D

const GAME_SCENE := preload("res://game.tscn")
var game: Node3D
var episode_index := -1
var base_seed := 1
var episode_seconds := 60.0
@onready var controller = $AIController3D

func _ready() -> void:
	for argument in OS.get_cmdline_args():
		if argument.begins_with("--env_seed="):
			base_seed = argument.get_slice("=", 1).to_int()
		elif argument.begins_with("--episode_seconds="):
			episode_seconds = maxf(0.1, argument.get_slice("=", 1).to_float())
	AudioServer.set_bus_mute(0, true)
	reset_episode()

func reset_episode() -> void:
	# Training infrastructure survives; gameplay, bullets and ragdolls are fresh.
	for child in get_children():
		if child != controller and child != $Sync and is_instance_valid(child):
			child.free()
	episode_index += 1
	seed(base_seed + episode_index)
	game = GAME_SCENE.instantiate()
	game.name = "Game"
	add_child(game)
	game.rng.seed = base_seed + episode_index
	var player = game.get_node("Player _ CharacterBody3D")
	player.ai_controlled = true
	player.debug_observations = false
	player.set_fps_mode(false)
	controller.bind_episode(game, player, episode_seconds)
	# No simulation before Python sends the first action, including after resets.
	game.process_mode = Node.PROCESS_MODE_DISABLED

func register_kill() -> void:
	# Enemies report kills through current_scene, which is the persistent trainer.
	game.register_kill()

func freeze_episode() -> void:
	for child in get_children():
		if child != controller and child != $Sync:
			child.process_mode = Node.PROCESS_MODE_DISABLED
