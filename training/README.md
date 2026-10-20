# Reinforcement-learning pipeline

Training runs on **Kaggle or Colab** with `zombie_training.ipynb`. Every game played
during training is recorded, and the Godot viewer replays any of them next to the
network that played it. The viewing PC needs only Godot: no Python, torch or GPU.

No successful survival agent has been trained yet. Local runs are wiring checks only.

## Files

- `../training.tscn`: persistent training scene; instances `game.tscn` for each round.
- `training_session.gd`: seeded round creation/cleanup; keeps Sync/controller alive.
- `zombie_rl_controller.gd`: 586 observations, seven action values, reward and endings.
- `training_sync.gd`: small subclass of the vendored Godot RL Agents Sync.
- `zombie_env.py`: Gymnasium adapter for one Godot process on Windows/Linux.
- `train.py`: PPO training, checkpoints, resume, time budget.
- `zombie_training.ipynb`: the Kaggle/Colab notebook (setup, checks, training, progress plot).
- `recording.py`: writes every episode and one weight snapshot per PPO rollout.
- `replay_format.py`: numpy-only reader and forward pass, used by tests and the notebook.
- `replay.tscn`, `replay_player.gd`: the viewer. `replay_archive.gd` reads recordings and
  reruns the network; `brain_view.gd`, `inputs_view.gd`, `timeline_view.gd` and
  `progress_view.gd` draw its panels.
- `replay_capture.gd`: read-only samples of models, animations and ragdoll bones.
- `smoke_test.py`, `smoke_test_replays.py`: connection and recording/playback checks.

The numerical observation schema is unchanged: see `../AI_OBSERVATIONS.md`.

## Training on Kaggle or Colab

Upload or open `training/zombie_training.ipynb` and follow the steps at its top: turn
internet on (Kaggle), add a `GITHUB_TOKEN` secret so it can clone this private repo,
and run all cells. It downloads Godot 4.6.3 for Linux, installs the pinned packages
in their own environment, runs the two wiring checks, then trains headless.

- Kaggle: use **Save Version → Save & Run All** for long runs; output stays in
  `/kaggle/working/runs`. To continue later, attach the previous version as an input;
  its `runs` folder is copied in and training resumes from the newest checkpoint.
- Colab: recordings are written directly to `MyDrive/zombie-apocalypse-runs`.
- `--hours` stops and saves cleanly before the session limit (default 11 h in the notebook).

Run locally only to check wiring (Linux example; `.venv` is ignored by git):

```bash
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python torch==2.14.1 --index-url https://download.pytorch.org/whl/cpu
uv pip install --python .venv/bin/python -r training/requirements.txt
godot --headless --path . --editor --import --quit
.venv/bin/python training/smoke_test.py
.venv/bin/python training/smoke_test_replays.py
```

The Godot executable defaults to `godot` on PATH (Linux) or the Windows path in
`zombie_env.py`; override with `--godot` or `GODOT_BIN`. Headless mode disables
rendering, not enemy collisions or ragdolls.

## Actions

The action space is `Box(-1, 1, shape=(7,))`, in this order:

| Index | Meaning |
| --- | --- |
| 0 | Movement world X |
| 1 | Movement world Z |
| 2 | Aim world X |
| 3 | Aim world Z |
| 4 | Shoot if positive |
| 5 | Request reload if positive |
| 6 | Request dash if positive |

Movement length is capped at 1. Aim X/Z is converted to the player's existing
`ai_aim_degrees`; a zero aim vector retains the last aim. This avoids wrapping a
neural angle output across 0/360 degrees while keeping every aiming angle possible.
Shooting is held across physics ticks; reload/dash are one-shot requests per action.
Sending another positive button value on the next decision is another request.
Ammo, cooldowns, automatic empty-magazine reload, dash commitment and slowdown
follow the existing player script.

Each decision advances four 60 Hz physics ticks (about 0.0667 simulation seconds).
The headless process can run faster than real time. It pauses between decisions,
so Python update time does not give enemies extra simulation time.

## Episodes, reward and correct terminal data

- Default round length: 60 simulation seconds. Configure with `--episode-seconds`.
- Death sets `terminated=True`; reaching the time limit sets `truncated=True`.
- Death takes priority if both happen in the same tick.
- Final observation/info is retained and sent before reset.
- Gymnasium/SB3 performs reset after receiving that final transition.
- Reset creates fresh player/enemies/projectiles/ragdolls, with full ammo/health.
- The gameplay instance stays frozen after reset until the first action arrives.
- `reset(seed=...)` reproduces that seed's starting round. Ordinary resets advance
  through the seed sequence. Changing the base seed restarts the Godot process.

Initial reward (not yet tuned):

```text
+0.05 per simulation second
+2.0 per kill
-0.02 per health point lost
-2.0 on death
```

Damage dealt does not yet have a separate reward. Collisions/knockdowns are not
directly rewarded, so repeatedly farming falls is not the initial objective.
These rewards must be evaluated against real learned behavior before treating
them as final. No resupply has been added; the player still has 60 total rounds.

The upstream Python wrapper duplicates done into both termination/truncation and
does not implement the Gymnasium terminal/reset contract we need. `ZombieEnv`
therefore uses its transport with an explicit Gymnasium adapter. This ensures PPO
can bootstrap timeouts correctly and SB3 can preserve `terminal_observation`.
The upstream addon itself is vendored unchanged.

## Training and checkpoints

```bash
python training/train.py --steps 2000000 --hours 11 --resume latest --output runs/ppo
```

- `--resume latest` picks the newest checkpoint or `survivor.zip` in `--output`
  (starts fresh if there is none). `--steps` counts additional decisions.
- `--n-steps` (default 2048) is the PPO rollout length. One weight snapshot is
  recorded per rollout, so this also sets how many snapshots are stored.
- Checkpoints every 10,000 decisions in `checkpoints/`, `survivor.zip` at the end,
  Monitor CSVs per session, and the recordings in `replays/`.
- Two 128-unit Tanh layers for the actor and two for the critic, `MlpPolicy`, CPU.

Do not claim survival performance from a short run. Judge it from the progress
screen or the notebook's plot across many games.

## Watching recorded games

![Replay with the policy network](../docs/screenshots/replay_policy.png)

These screenshots come from untrained wiring-check recordings, not a trained survivor.
The value network view and the progress screen:

![Replay with the value network](../docs/screenshots/replay_value.png)
![Training progress screen](../docs/screenshots/replay_progress.png)

Copy the downloaded `ppo` folder into `training/runs/` (or anywhere), open
`training/replay.tscn` in the editor and press **F6**. The viewer opens the last game
you watched, or the newest one. **All games** (or Tab) shows every recorded game in
training order: survival time, kills or reward against training steps, with a
rolling average. Click a dot to watch that game. **Open folder…** picks another
download location; the choice is remembered.

The game view uses the original rooftop, city, characters and gun, seen from the
same overhead camera, with the same HUD as the game. Bottom left shows what the
network pressed, drawn as the controls a player would use (ZQSD, Space, R, the
mouse button and the aim direction). Movement is analog, so the stick shows the
exact vector and the keys light up in proportion.

The right panel shows the network at the current decision:

- **What it sees**: the 586 inputs as rows, the survivor first and then the 18
  enemy slots, nearest first. Hover a square for its name and value; hovering a
  row circles that enemy (or you) in the game view.
- **Layer 1 / Layer 2**: the 128 neurons of each hidden layer.
- **Decision**: the action means, and the value after sampling/clipping that was
  actually sent to the game. The **Value** tab shows the critic instead.
- Lines are the strongest contributions (input × weight) at that moment. Click a
  neuron to see everything feeding it and where it sends its signal.

Orange is positive, blue negative, brighter is stronger. The timeline shows health,
the critic's value estimate and kills; click or drag to seek.

Keys: Space play/pause, Left/Right one decision (Shift: one second), Home/End,
Page Up/Page Down previous/next game, 1/2 policy/value, Tab all games.

The viewer recomputes every activation in GDScript from the weights that made
that decision. If they don't reproduce the value/log-probability recorded live,
the panel says so. Headless check of a recording:

```bash
godot --headless --path . res://training/replay.tscn -- --run=/path/to/runs --check
```

### What is stored

One folder per training session under `replays/`, so resumed runs never overwrite:

- `manifest.json`: format 2, observation schema, the weight layout.
- `policies.json` and `policies/<sha256>.bin`: raw float32 weights, input-major,
  saved once before each PPO rollout and checked against their hash when loaded.
- `episodes/<id>.bin.gz`: float32 observations (T+1), applied and sampled actions,
  rewards, live values and log-probabilities.
- `episodes/<id>.json.gz`: world samples (T+1), status, seed, training step range
  and which weight snapshot made each decision.
- `index.json`: one summary row per game for the progress screen.

Games are saved when they end, and partly after each rollout (`in_progress`, then
`interrupted` if the session stops). A hard crash can lose decisions since the last
rollout. Samples are at 15 decisions/s; playback interpolates between them, but
events shorter than a sample can be missed and there is no audio or muzzle flash.
A 20 s game is about 0.4 MB, a weight snapshot about 0.74 MB. Keep the matching
project/assets for playback, and always download the whole folder including
`policies/`.

## Diagnostics

- Godot output: ignored `training/runs/godot-11008.log`.
- A connection failure raises an error instead of silently falling back to training
  from human inputs. The adapter closes its own child process when finished.
- `game.tscn` remains the normal F6 human-play scene. `training.tscn` is launched
  automatically by Python; opening it alone does not start a trainer.
- The addon contains optional C# ONNX inference files, but this pipeline uses
  Python inference/training and does not instantiate them. The standard Godot
  executable is used for the checks; no .NET installation is required here.
- Only one instance is supported by this first adapter. Parallel workers and
  throughput benchmarking are subsequent work.

## Third-party component

Godot RL Agents plugin, MIT, by Edward Beeching and contributors:
https://github.com/edbeeching/godot_rl_agents_plugin

Vendored source revision: `998c357a0cd09b37f40a36d70c7867fc9f682338`.
License: `../addons/godot_rl_agents/LICENSE`.
Python package: `godot-rl==0.8.2`. Communication protocol: 0.7.
