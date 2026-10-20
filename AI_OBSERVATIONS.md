# AI observations - schema v3

`get_observation()` returns 590 floats: 32 player fields, then 18 enemy slots
with 31 fields each. Slot order is nearest first by 3D distance, with instance ID
as the tie breaker. Empty slots are all zero; dead enemies leave the group.
All living enemies are observable, including hidden wall climbers.

Each field below is listed in its exact array order, starting at zero. Use
`32 + slot * 31 + enemy_field_index` to find an enemy value in the flat array.
Names are also available in PLAYER_OBSERVATION_FIELDS and ENEMY_OBSERVATION_FIELDS.
This replaces schema v2 (586 values, no cursor) and the earlier 149-value schema.

## Player fields

0. `health`
1. `magazine_ammo`
2. `reserve_ammo`
3. `reloading`
4. `dash_cooldown`
5. `position_x`
6. `position_y`
7. `position_z`
8. `velocity_x`
9. `velocity_y`
10. `velocity_z`
11. `aim_x`
12. `aim_z`
13. `reload_remaining`
14. `shot_cooldown`
15. `dash_remaining`
16. `dash_direction_x`
17. `dash_direction_z`
18. `last_move_direction_x`
19. `last_move_direction_z`
20. `shooting_slow_remaining`
21. `hurt_immunity_remaining`
22. `grounded`
23. `dead`
24. `edge_negative_x`
25. `edge_positive_x`
26. `edge_negative_z`
27. `edge_positive_z`
28. `cursor_x`
29. `cursor_z`
30. `cursor_velocity_x`
31. `cursor_velocity_z`

## Fields in each enemy slot

0. `present`
1. `relative_x`
2. `relative_y`
3. `relative_z`
4. `velocity_x`
5. `velocity_z`
6. `hound`
7. `climbing`
8. `velocity_y`
9. `health`
10. `heading_x`
11. `heading_z`
12. `chasing`
13. `warning`
14. `charging`
15. `skidding`
16. `fallen`
17. `recovering`
18. `attacking`
19. `state_remaining`
20. `charge_cooldown`
21. `attack_cooldown`
22. `grace_remaining`
23. `collision_stumble_cooldown`
24. `balance_stress`
25. `charge_direction_x`
26. `charge_direction_z`
27. `run_speed`
28. `charge_speed`
29. `turn_speed`
30. `climb_remaining`

## Interpretation and scales

Flags are 0/1. Climbing overrides combat state: combat state flags and state timer
are zero while climbing. Hounds expose windup as `warning`, then `charging`, then
`recovering`. Charge direction is the actual committed world X/Z direction during
warning/charge, and zero otherwise. It does not reveal a future target decision.
State remaining is in seconds divided by 3, not a fraction of the current phase.

Player position X/Y/Z uses scales 16/64/10. Relative enemy XYZ uses 32/64/20.
Horizontal velocity uses 15, vertical velocity 25. Aim and heading use signed world
direction components; aim is the actual weapon direction, not the requested angle.
Climbing velocity is calculated from the existing climb path; fallen velocity is
read from the existing ragdoll hips when available. Other enemies use momentum X/Z
and body velocity Y.

The cursor is the AI's virtual mouse pointer on the aim plane: position relative
to the player on the enemy scales (32/20), velocity divided by `ai_cursor_max_speed`.

Edge distances are signed distance to the four arena bounds (-16/+16 X, -10/+10 Z),
divided by full arena width/depth (32/20). Zero means on the edge, negative outside.

Player timers use their exported duration, except shot cooldown 0.35s, shooting
slowdown 0.22s and hurt immunity 0.45s. Health uses 100, reserve ammo 48, magazine
uses magazine_size. Enemy health uses 50 for hounds and 75 for zombies. Enemy
charge cooldown uses 2s, attack cooldown 0.9s, grace 1s, collision stumble cooldown
4s, balance stress 0.65, speeds 15 and turn speed PI. Remaining climb time is a
fraction of the entire rush + wall climb + 0.8s landing sequence.

Nonnegative values clamp to [0,1]; signed values clamp to [-1,1]. Direction vectors
are already normalized by gameplay. These scales match the current arena/rules.
Update the schema/scales if those rules change. No gameplay/physics is changed.

Debug Observations prints once per second: named player data, named nearest enemy
data, and every observed hound's phase and timers in seconds. The full numeric
array still includes every slot. Disable that Inspector checkbox before training.
