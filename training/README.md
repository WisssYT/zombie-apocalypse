# Single-instance reinforcement-learning pipeline

Status: Godot/Python connection, controls, observations, rewards and round resets.
No successful survival agent has been trained. Main training is intended for
Colab/Kaggle; the local commands below are integration checks and optional previews.

Validated on Windows with Godot 4.6.2 and Python 3.12: environment checker,
movement/aim/fire, reload/dash rules, death vs timeout, seeded reset, SB3 automatic
reset/terminal observations, and untrained network creation/save/load. Linux cloud
execution is not yet tested. A separate replay integration test performs only
128 decisions and four tiny PPO updates. This is a wiring check, not a survival
experiment or a trained game-playing agent.

## Files

- `../training.tscn`: persistent training scene; instances `game.tscn` for each round.
- `training_session.gd`: seeded round creation/cleanup; keeps Sync/controller alive.
- `zombie_rl_controller.gd`: 586 observations, seven action values, reward and endings.
- `training_sync.gd`: small subclass of the vendored Godot RL Agents Sync.
- `zombie_env.py`: Gymnasium adapter for one Godot process on Windows/Linux.
- `smoke_test.py`: exercises the live game connection and resets.
- `train.py`: PPO training/checkpoint/resume entry point.
- `recording.py`: compressed episode records and per-rollout inference weights.
- `replay_data.py`: checksum verification and actual actor/critic reconstruction.
- `replay_game.py`, `replay.tscn`, `replay_player.gd`, `brain_view.gd`: native Godot
  gameplay and neuron viewer. No HTML, browser, web server or video required.
- `replay_capture.gd`: read-only samples of models, animations and ragdoll bones.
- `smoke_test_replays.py`: validates recordings across policy updates and resets.

The numerical observation schema is unchanged: see `../AI_OBSERVATIONS.md`.
The normal playable `game.tscn`, enemy controller and ragdoll script are unchanged.
No F2 switch, in-game console or neural auto-aim has been added.

## Runtime

Use Python 3.12 and install in a virtual environment. On Windows:

```powershell
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r training\requirements.txt
.\.venv\Scripts\python.exe training\smoke_test.py
```

These commands are run from the Godot project folder. The Python adapter launches
and closes Godot itself. Do not start `training.tscn` separately at the same time.
The first launch imports assets if necessary; run the import command below first
on a fresh machine. The Godot executable defaults to the existing Windows path;
override it with `--godot "FULL_PATH"` or the `GODOT_BIN` environment variable.

On Linux (including a notebook runtime), the same source project can run with a
Godot 4.6.2 Linux executable. No graphical editor interaction is needed:

```bash
/path/to/godot --headless --path /path/to/project --editor --import --quit
/path/to/python /path/to/project/training/smoke_test.py --godot /path/to/godot
```

The cloud notebook and export/upload packaging are the next step. A notebook runtime
has not been configured or tested yet. Keep all game physics active in training;
headless mode disables rendering, not enemy collisions or ragdolls.

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

## Training and checkpoints (after the connection checks)

```powershell
.\.venv\Scripts\python.exe training\train.py --steps 100000
```

For Linux/notebooks, use the notebook's Python executable and pass `--godot`.
Start with CPU for this small numerical policy. The network has two 128-unit
layers for the actor and two 128-unit layers for the critic. This Gymnasium
adapter returns a flat array, so it uses `MlpPolicy`.

Outputs go to ignored `training/runs/ppo/`: episode CSV, checkpoints every 10,000
decisions, state/brain replay archives, and `survivor.zip` after a completed run. Preserve these outside an
ephemeral cloud runtime. To resume:

```powershell
.\.venv\Scripts\python.exe training\train.py --resume training\runs\ppo\survivor.zip --steps 100000
```

Add `--show` for a local window during checks. This is optional; cloud training
should normally stay headless. It may be slower than headless execution.

Do not claim survival performance from a short smoke run. Evaluate saved models
on new seeds and report actual survival/kills before scaling instance count.

## Watch every episode and inspect its actual brain

Normal training records **every episode by default**, without rendering images.
Use `--no-replays` only if you deliberately want to disable this. Each training
invocation creates a new archive under `OUTPUT/replays/TIMESTAMP-ID/`, so resuming
training does not overwrite previous episodes.

After downloading the complete archive from Colab/Kaggle, watch it on your PC:

```powershell
.\.venv\Scripts\python.exe training\replay_game.py --run training\runs\ppo
```

That command selects the latest archive in the output folder and its last saved
episode. Or pass the exact `replays/TIMESTAMP-ID` folder to open an older archive.
The window is **Godot itself**, using the original rooftop, city, characters and
gun. The game code does not run during playback: recorded transforms, animation
positions and ragdoll bone poses drive the models directly.

In the viewer:

- Choose an episode with the dropdown. Python prepares that episode's neural
  data in the background; allow a few seconds for loading.
- Space or the Play button pauses/resumes. Left/right arrows and the Step buttons
  move by one recorded decision. Drag the slider to seek. Speed ranges from 0.25x
  to 4x. The final scene has no further decision and therefore no neuron display.
- Switch between **actor** (action selection) and **critic** (future reward estimate).
- All 586 input values and both 128-neuron hidden layers are shown. Amber is
  positive, blue is negative, and brightness indicates magnitude.
- Click a hidden/output neuron to show its incoming weight connections, bias and
  strongest input contributions. Hover over a neuron/input for its numerical value.
- Action bars show the actual commands sent to Godot. The network's action means
  appear at the output neurons; PPO samples actions around these means before
  clipping them to [-1, 1]. The actual samples are recorded too.
- The integrity panel compares reconstructed value/log-probability with their
  **live inference values** recorded at the time. A mismatch is displayed clearly.

To list or select an episode from the command line:

```powershell
.\.venv\Scripts\python.exe training\replay_game.py --run training\runs\ppo --list
.\.venv\Scripts\python.exe training\replay_game.py --run training\runs\ppo --episode episode-000003
```

For an immediate **untrained** preview using the local viewer-test recording:

```powershell
.\.venv\Scripts\python.exe training\replay_game.py --run training\runs\viewer-demo --episode episode-000000
```

That ignored local demo is labelled `UNTRAINED NETWORK / VIEWER TEST`. Its initial
output biases were set in an external test fixture to keep the player on the roof
long enough to test enemy recording. It is not a learned survival strategy and
those fixture settings are not used by `train.py`. The demo is not committed.

### Precision and storage

- `.npz`: losslessly compressed float32 observations (T+1), applied actions, raw
  sampled actions, rewards, live values/log-probabilities, termination flags and
  **a policy ID for each individual decision**.
- `.json.gz`: compressed actual world samples (T+1), episode status/results and
  visual poses. Persistent visual IDs survive enemies switching into ragdolls.
- `policies/SHA256.pt`: the real inference weights, saved once before each PPO
  rollout, shared across every decision using them. We verify the file checksum
  before loading. These weights include actor, critic and action randomness scale.
  They are not substitutes for full optimizer/resume checkpoints.
- `index.json`: survival time, kills, health, reward, status and episode bytes.
- `manifest.json`: format, observation schema and Python/library versions.

PPO updates after collecting a rollout. A single episode can cross several
updates; its decisions therefore may refer to different weight snapshots. No
"nearest checkpoint" approximation is used. Activations are computed from each
recorded observation and its matching weights when opening a replay, rather than
being stored at every training step. Neuron meanings are not invented labels.

Full episodes are saved at termination/timeout. A partial episode is also saved
after each rollout and on normal close, with `in_progress`/`interrupted` status.
A hard runtime crash can lose decisions since the last completed rollout.

Samples are at 15 decisions/s, **not every rendered/physics frame**. Fast events
between samples can be missed, and playback currently has no audio or transient
muzzle flashes. Ragdoll bones are captured read-only at that same sampling rate;
their physics is not rerun or changed. This reproduces sampled state, rather than
claiming a pixel-perfect video. Keep the matching project/assets for visual playback.

Recording uses CPU, bandwidth between local Godot/Python processes, and storage;
it is not free. The 20.2-second local demo used about 0.37 MB of compressed episode
data, plus one roughly 0.74 MB weight snapshot. Actual sizes grow with enemies,
ragdolls, episode length and number of updates. Check real archive sizes before
scaling workers. Download the **whole archive including policies**, not just NPZs.
Temporary expanded data is created only for local viewing and removed on exit.

Run the replay integration check:

```powershell
.\.venv\Scripts\python.exe training\smoke_test_replays.py
```

It checks actual sampled/clipped actions, actor/critic inference equality, policy
changes within an episode, auto-reset separation, partial saves, checksum rejection,
and native Godot model playback. Cloud execution is still untested.

## Diagnostics

- Godot output: ignored `training/runs/godot-11008.log`.
- A connection failure raises an error instead of silently falling back to training
  from human inputs. The adapter closes its own child process when finished.
- `game.tscn` remains the normal F6 human-play scene. `training.tscn` is launched
  automatically by Python; opening it alone does not start a trainer.
- The addon contains optional C# ONNX inference files, but this pipeline uses
  Python inference/training and does not instantiate them. The standard Godot
  executable is used for the checks; no .NET installation is required here.
- Only one instance is supported by this first adapter. Parallel workers,
  throughput benchmarking and a cloud notebook are subsequent work.

## Third-party component

Godot RL Agents plugin, MIT, by Edward Beeching and contributors:
https://github.com/edbeeching/godot_rl_agents_plugin

Vendored source revision: `998c357a0cd09b37f40a36d70c7867fc9f682338`.
License: `../addons/godot_rl_agents/LICENSE`.
Python package: `godot-rl==0.8.2`. Communication protocol: 0.7.
