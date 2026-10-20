extends "res://addons/godot_rl_agents/sync.gd"

# Reset the world after this physics callback, before Sync sends the reset reply.
# The upstream default only raises needs_reset for the game to handle itself.
func _reset_agents(agents = all_agents):
	for agent in agents:
		agent.reset()
