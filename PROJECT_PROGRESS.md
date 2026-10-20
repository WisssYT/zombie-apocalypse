# Zombie Apocalypse - project progress

Updated: 2026-10-20

## Where we are now

The game is playable. We have added controls that code can drive and a numerical
description of the game for a future reinforcement-learning agent.

**A single-instance Python training connection is implemented, and runs on Linux.**
The separate `training.tscn` and `training/` scripts provide actions, observations,
initial rewards and resets. Training is meant to run on Kaggle/Colab with
`training/zombie_training.ipynb`; no long training session has been run yet.
See [training/README.md](training/README.md) for commands and the current pipeline.

Every training game is recorded with the weight snapshot that played it. The
viewer (`training/replay.tscn`, F6) replays any game with the original assets and
shows the network beside it: the inputs it saw, both hidden layers, its decision,
and the controls it pressed. A progress screen plots every recorded game against
training steps. The viewer recomputes the network in GDScript, so watching needs
only Godot on the PC. Only untrained wiring-check recordings exist so far.
Checking **Ai Controlled** selects the code-controlled inputs. It does not create
an intelligent player: without commands, the player stays still and does not shoot.

## Goal and decisions

- Build a YouTube project exploring whether a neural network can survive the game
  and discover tactics such as making enemies collide.
- The original idea was camera-image observations. We decided to use numerical
  game information, including enemy coordinates, to make the first experiment easier.
- The agent will use top-down controls. It will not use first-person camera images.
- Eventually train using Colab or Kaggle, then bring saved models back to Windows
  to watch and record them playing.
- The agent will learn decisions through reinforcement learning; its combat
  strategies have not been hardcoded.

## Running the project

- Engine: Godot 4.6.2 on Windows, Compatibility renderer, Jolt physics.
- Project folder: `C:\Users\user\Projects\Zombie Apocalypse\zombie-apocalypse`
- Godot executable:
  `C:\Users\user\Downloads\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe`
- No main scene is configured. Open `game.tscn` and press **F6**.
- **F8** stops a game launched from the editor.
- Fullscreen was disabled in the project settings; the game now uses the default
  windowed mode.
- In Godot, select `Player _ CharacterBody3D` in the scene to find the exported
  **Ai Controlled**, **Ai Aim Degrees** and **Debug Observations** properties.

## Existing game

- An elevated rectangular rooftop with enemies climbing its four walls.
- ZQSD movement, mouse aim, left-click shooting, R reload, Space dash.
- Human mode: C switches between overhead and first-person cameras; Esc releases
  the first-person mouse. Enter restarts after death.
- Health, damage, death, kills, survival time, bullets and trails.
- A 12-round magazine, 48 reserve rounds, 1.25-second reload and 0.2-second firing interval.
- Shooting slows movement; reloading slows it further.
- Dash has a committed direction and cooldown, gives no invulnerability and blocks
  shooting. Starting a dash cancels an unfinished reload.
- Zombies have momentum and limited turning. Sharp turns can cause skids/falls.
- Hounds warn, commit to a straight charge, then recover. Every fourth spawned
  enemy is a hound; the normal spawning cap is 18 living enemies.
- Charging hounds can knock zombies down; zombie collisions can also cause falls.

## Visual and sound work retained

- Bitkiln PSX zombie/hound models and the heyheythere survivor woman with backpack.
- Ace Spectre PS1-style AK-74, first-person arms and existing character animations.
- Ruined skyscrapers at varied heights, skyline and atmospheric lighting/fog.
- Dark, low-resolution worn concrete rooftop textures from Poly Haven.
- Gun and muzzle recoil; first-person camera recoil; no overhead camera shake.
- The chosen Pixabay AK-74 shot and the **first** OpenGameArt reload attachment,
  `gunreload1.wav`. The reload sound was fitted to the existing gameplay timing.
- Sources, adaptations and licenses are recorded in `CREDITS.txt` and asset source files.

Important preferences: do not restore the rejected sunset rooftop redesign.
Show a reference/concept before another major environment redesign. Preserve the
user's finished ragdoll implementation; observation work only reads its data.

## AI controls implemented

These fields are in `player___character_body_3d.gd`:

| Field | Purpose |
| --- | --- |
| `ai_controlled` | Choose code inputs instead of human controls. Defaults to false. |
| `ai_move` | `Vector2` movement in world X/Z, limited to length 1. |
| `ai_aim_degrees` | Requested aiming angle in degrees. |
| `ai_shoot` | Hold shooting while true. |
| `ai_reload_requested` | Request one reload; consumed on the next physics tick. |
| `ai_dash_requested` | Request one dash; consumed on the next physics tick. |

Movement convention: `Vector2(1, 0)` means world +X;
`Vector2(0, -1)` means world -Z. Movement and aim are independent.

Aiming convention: 0 degrees is +X; 90 degrees is -Z; 180 degrees is -X.
Any angle is supported, including 48 degrees. The gun directly adopts the requested
angle; human-like turn-rate smoothing has not been added.

In AI mode:

- Human movement, mouse aiming, left-click, R, Space, C and mouse-look are ignored.
- The game uses the overhead camera, including if AI mode is enabled while in FPS.
- The same ammo, cooldown, slowdown, dash and recoil rules still apply.
- Movement and shooting persist until their variables change. Reload/dash requests
  are consumed once, including requests blocked by gameplay restrictions.
- Death clears the AI action variables. The separate training scene implements
  round resets; normal human play still uses Enter after death.

The F2 toggle was removed. There is no in-game console or keyboard AI toggle.
The training controller's `set_action()` now receives a seven-value continuous action:
move X/Z, aim X/Z, shoot, reload and dash. It converts the aim vector to the existing
angle field. The normal player script still holds the input variables listed above.

## Observations implemented

`get_observation()` returns a fixed array of **586 floats**:

```text
28 player values + 18 enemy slots x 31 values = 586
```

The array is a snapshot when called. It does not change gameplay or make decisions.
Calling it repeatedly reads updated values. `_ready()` runs once, whereas
`_physics_process()` runs repeatedly.

Player inputs include health/ammo, world position and movement, actual aiming
direction, reload/shoot/dash timers, committed dash direction, recent movement
direction, movement slowdown, temporary damage immunity, grounded/dead flags and
distances to all four rooftop boundaries.

Each enemy slot includes:

- Presence, relative XYZ position, XYZ movement, health, heading and enemy type.
- Climbing and remaining climb time.
- Separate chase, warning, charge, skid, fallen, recovery and attack flags.
- Remaining phase time, charge/attack cooldowns and grace time.
- Knockdown cooldown and balance stress, useful for collision/skid tactics.
- The hound's committed charge direction during warning/charge.
- Running speed, charge speed and turning speed.

All living enemies are included, even climbers outside the camera view. They are
sorted by 3D distance to the player, nearest first. Empty slots contain zeros, and
dead enemies leave the observation group. Values use documented scales and bounds.
Climbing motion is derived from the existing path; fallen motion reads the existing
ragdoll hips velocity without changing the physics.

See [AI_OBSERVATIONS.md](AI_OBSERVATIONS.md) for exact field order, indices and scales.
That schema replaces the earlier 5-value and 149-value versions. A future trainer
must use the current 586-value layout. Slot identity can change as distance order changes.

### Debug output

Enable **Debug Observations** on the player and run with F6. Once per second,
Godot's Output panel shows the count, named player values, named nearest-enemy values
and every observed hound's phase/timers. Showing one enemy in the debug summary
does not limit the full numerical array.

The checkbox is currently **off in the saved scene**. Enable it when needed and
disable it before long training runs. Avoid printing every physics tick.

## Neural network setup

Use Python with Stable Baselines3 PPO and an `MlpPolicy` for numerical inputs.
`training/train.py` uses two 128-unit layers for the action network and two 128-unit
layers for the value network. This is a starting experiment, not a successful
trained survival model or a proven configuration for this game.

PPO uses rewards from gameplay to update the network. Merely creating the network
does not establish skill. `training/zombie_env.py` now provides the Gymnasium
environment and starts Godot automatically. It preserves the final observation
and distinguishes death from timeout so PPO can handle both correctly.

With a small numerical-input PPO policy, benchmark CPU training before assuming a
cloud GPU helps. Godot simulation speed and available CPU cores can be the bottleneck.
Numerical observations allow cloud Godot runs without graphics rendering.

References:

- [Stable Baselines3 PPO](https://stable-baselines3.readthedocs.io/en/master/modules/ppo.html)
- [Policy networks](https://stable-baselines3.readthedocs.io/en/master/guide/custom_policy.html)
- [Custom environments](https://stable-baselines3.readthedocs.io/en/master/guide/custom_env.html)
- [Godot RL Agents](https://github.com/edbeeching/godot_rl_agents), now used by the
  single-instance pipeline. The Godot addon is vendored under `addons/` with its
  MIT license; the isolated Python environment uses `godot-rl==0.8.2`.

## Next steps, in order

1. Single-instance checks are complete on Windows: actions, seeded resets, death,
   timeouts, final observations and SB3 auto-reset passed. Network creation and
   save/load were checked without learning a policy. Each action advances four
   60 Hz ticks. Re-run `training/smoke_test.py` after pipeline changes.
2. Run `training/zombie_training.ipynb` on Kaggle/Colab. The connection and replay
   checks pass on Linux (Godot 4.6.3) locally; the notebook itself is untested in the cloud.
3. Run a short PPO experiment in the notebook. Initial reward is +0.05 per second,
   +2 per kill, -0.02 per health point lost and -2 on death. Separate hit/damage-dealt
   rewards and collision telemetry are not implemented. Tune using actual behavior.
4. Save/resume checkpoints and evaluate on new spawn sequences. Track survival,
   kills, damage and ammo use; add collision statistics for the YouTube experiment.
5. Benchmark 1, 2, 4, 8 and more instances before choosing a count. Only one process
   is supported by the current adapter; 100 instances is not assumed feasible on
   a notebook runtime. Keep whichever count produces the best overall throughput.

The current game has 60 total rounds and endless spawning. Start with timed rounds
using that ammo supply; decide on resupply before pursuing indefinite combat survival.

## Verification and working preferences

- Headless checks covered AI/human input separation, firing cadence, reload ammo,
  dash restrictions, recoil, observation shape/padding, sorting and enemy removal.
- Combat observation checks exercised real hound warning-to-charge and
  recovery-to-chase transitions, plus climbing/fallen movement reads.
- Pipeline checks passed the Stable Baselines3 environment checker, same-seed
  transition reproduction, invalid-action rejection and timeout bootstrapping.
- Local test stack: Python 3.12, godot-rl 0.8.2, SB3 2.4.0, Gymnasium 1.0.0,
  NumPy 1.26.4 and PyTorch 2.14.1. Packages are isolated in ignored `.venv/`.
- Enemy controller and ragdoll behavior were not modified for the observation work.
- Replay checks covered 128 actual decisions across policy updates, live value/
  log-probability agreement, sampled vs clipped actions, terminal vs reset frames,
  checkpoint checksum rejection, and native Godot playback. A separate fixture
  captured and replayed existing ragdoll bone poses without changing their physics.
- The normal scene, enemy controller, ragdoll script and skyline resource remained
  unchanged. Local GUI capture was checked on Intel UHD. Linux cloud training
  and large-worker recording throughput still need validation.
- Temporary check scripts/backups are outside the project under
  `C:\Users\user\Documents\Codex\2026-10-19\i-m-building-a-3d-zombie\work`.
- The user wants simple explanations and sometimes wants to code changes personally.
  Respect that when giving tutorials; make edits directly when explicitly requested.

## Useful files and Git

| File | Role |
| --- | --- |
| `game.tscn` | Main playable scene. |
| `player___character_body_3d.gd` | Human/AI controls, combat, cameras, recoil and observations. |
| `AI_OBSERVATIONS.md` | Exact observation schema. |
| `training.tscn`, `training/README.md` | Separate training scene and pipeline instructions. |
| `training/zombie_env.py`, `training/train.py` | Python environment and PPO entry point. |
| `survival.gd` | Spawning, HUD, kills, manual restart. |
| `enemy_controller.gd` | Zombie/hound movement, charges, collisions and combat. |
| `enemy_ragdoll.gd` | Existing finished ragdoll implementation. |
| `survivor_visual.gd`, `first_person_arms.gd` | Player visuals and arms. |
| `CREDITS.txt`, `audio/AK_AUDIO_SOURCE.txt` | Asset/sound attribution and adaptations. |

GitHub: **WisssYT/zombie-apocalypse**, private repository, branch **main**.
Recoil/audio were already pushed in `1d62d30`; this summary accompanies the later
AI groundwork and the current saved project/editor changes. No substantive
survival training experiment has been completed; no survival results should be claimed yet.
