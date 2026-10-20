# Zombie Apocalypse RL: context handoff

Written 2026-10-20, at the end of the training/replay tooling work, before moving
on to the YouTube video. Code is on GitHub `WisssYT/zombie-apocalypse` (public),
branch `main`, latest commit `e46d62b`. Detailed references: `training/README.md`
(pipeline, viewer, storage), `AI_OBSERVATIONS.md` (input layout),
`PROJECT_PROGRESS.md` (game history), `CREDITS.txt` (assets and licences).

## The project in one paragraph

A PS1-style top-down zombie survival game in Godot 4.6 (rooftop arena, zombies and
hounds climbing the walls, AK-74, ragdolls). A reinforcement-learning agent (PPO,
Stable-Baselines3) learns to play it from numbers, not pixels. Training runs on
Kaggle (or Colab), never on the local PC. Every game it plays is recorded and can
be rewatched in Godot with the network that played it, then exported to video.
The goal is a YouTube video about whether a neural network can learn to survive,
dodge, and maybe discover tactics like making zombies collide.

## Status right now

- **Built and tested locally (Linux, headless):** game-to-Python connection, rewards,
  recording, replay viewer, evaluation, video export, collision/fall/dodge stats.
- **Not done yet:** any real training. No trained agent exists; all recordings so far
  are short untrained wiring tests.
- **In progress:** the first 30-minute Kaggle test run (`HOURS = 0.5`). The first
  attempt crashed on Kaggle's matplotlib setting; that is fixed (commit `4c9a2dd`).
- **Waiting for from that run:** the `fps` number in the training log (decisions per
  second), the evaluation summary line, and any errors.

## How the AI plays

- **What it sees (590 numbers, schema v3):** 32 about the player (health, ammo,
  position, velocity, aim, timers, distance to the roof edges, its mouse cursor
  position and speed) and 18 enemy slots of 31 numbers, nearest enemy first
  (relative position, velocity, zombie/hound, climbing, chase/warning/charge/fallen
  states, timers, balance). Exact order in `AI_OBSERVATIONS.md`.
- **What it does (7 numbers, each -1..1):** move X/Z, mouse movement X/Z, shoot,
  reload, dash. A decision every 4 physics ticks (15 per game second).
- **Human-style aiming:** it moves a virtual mouse cursor; the gun points from the
  player to the cursor, the same rule as human mouse aiming. Cursor speed is capped
  at 60 units/s and reaches it in about 0.1 s, so aim is continuous and can't snap.
  The cursor stays inside the overhead view. No reaction delay yet: it responds
  within one decision (0.07 s) where a human needs about 0.2 s.
- **Network:** two separate MLPs, 128 + 128 Tanh units each, one choosing actions
  (policy) and one estimating how well things are going (value). About 190k weights.
  CPU only; a GPU would not help (the game simulation is the bottleneck).

## Reward (favours survival and dodging)

| Term | Weight | Notes |
| --- | --- | --- |
| alive | +0.1 per second | a full 60 s round = +6 |
| damage | -0.05 per health point | zombie bite -0.5, hound charge -0.9 |
| death | -3 | |
| kill | +0.5 | useful, not the goal |
| dodge | +0.5 per dodged hound charge | player moved >= 1 m off the locked spot and the charge came within 3 m without hitting |

Collisions and falls are counted, not rewarded. Weights are set from Python
(`DEFAULT_REWARD` in `training/zombie_env.py`), changeable with `--reward name=value`
or `REWARD = {...}` in the notebook, and stored in every recording. Rounds last 60
simulated seconds. Ammo: 60 rounds total, no resupply (open decision).

## Exploration noise and evaluation

During training PPO adds deliberate random noise to every action (starting std
`--noise`, default 1.0; PPO learns how much to keep). The viewer shows each
attempt's noise. `training/evaluate.py` plays a saved model with the noise off
(always its most likely action) on rounds it never trained on (seeds from
1,000,000), records them as evaluation games and prints averages. The notebook runs
10 evaluation games after each training session.

## Stats counted by the game

Per round: zombie-on-zombie collisions that knock someone down, hound charges that
knock a zombie down, zombies tripping on tight turns, enemies falling off the
building, hound charges dodged. They appear on the human HUD, in the training CSV,
in each game's summary (`index.json`), and in the viewer.

## Training on Kaggle

1. kaggle.com, phone-verified account (needed for internet in notebooks).
2. Create → New Notebook → File → Import Notebook →
   `https://github.com/WisssYT/zombie-apocalypse/blob/main/training/zombie_training.ipynb`
3. Session options: Internet **On**, Accelerator **None**, Persistence any (with
   "No persistence", download results before stopping).
4. First cell: `HOURS = 0.5` for a test, `11` for a real session. Also `NOISE`,
   `REWARD`, `EPISODE_SECONDS`.
5. Run all. The notebook clones the latest code from GitHub every run, downloads
   Godot 4.6.3 for Linux, installs pinned packages in their own environment, runs
   the wiring checks, trains, evaluates, plots survival.
6. Download: add a cell `!cd /kaggle/working && zip -qr runs.zip runs`, then download
   `runs.zip` from Output.
7. Long runs: Save Version → Save & Run All. To continue, attach the previous version
   as an input; training resumes from the newest checkpoint and the training-hours
   clock keeps counting.

Code changes reach Kaggle automatically (the clone cell); only changes to the
notebook file itself need a re-import.

**Rough training-time expectations** (honest guesses, not measured): stops dying
stupidly after 100k–500k decisions, basic play 1M–5M, good play 5M–20M+, clever
tactics like making zombies collide maybe never unless rewarded. At about 100
decisions/s (measured on the weak local PC) 1M is about 3 hours. Running several
games in parallel would give about 2.5–3x on Kaggle's 4 cores (not built yet).

## Watching and exporting replays (on the PC)

- Unzip so you get `training/runs/ppo/...`, open `training/replay.tscn` in Godot, F6.
  Only Godot is needed on the PC (no Python): the viewer recomputes the network
  from the saved weights and checks it against what the network did live.
- **Layout (speedrun overlay):**
  - **Overhead feed:** the game's own HUD, plus a NohBoard-style input display
    (ZQSD, Space, R, mouse with push arrow, stick, aim dial) and the AI's mouse
    pointer.
  - **First-person feed:** the game's FPS camera and arms.
  - **Run panel:** attempt number, training steps and hours, noise or EVALUATION,
    run timer (green alive, red died, gold survived), dodged/collisions/fell-off
    counts, kill splits compared with the best attempt.
  - **Network:** an LED-style block (inputs, layer 1, layer 2, output meters with a
    tick for what was actually sent), POLICY/VALUE switch, value strip.
  - **Bottom bar:** previous/play/next, speed, a track with ticks (gold kill,
    red hit, green dodge, white collision, cyan fall), SAVE VIDEO, ATTEMPTS.
- **ATTEMPTS screen (Tab):** every game plotted against training steps by time,
  dodged, kills, collisions, fell off or reward, with a running average; evaluation
  games are diamonds. Hover shows "after N training steps (X h)". Click to watch.
- **Keys:** Space, Left/Right (Shift = 1 s), Home/End, PgUp/PgDn attempts, 1/2
  policy/value, Tab attempts.
- **Video:** SAVE VIDEO writes `training/videos/attempt-N.avi`, 1280x720 at 30 fps,
  MJPEG, about 3.7 MB/s (a 60 s attempt is about 220 MB). Terminal:
  `godot --path . res://training/replay.tscn -- --run=training/runs/ppo --episode=12 --save-video`.
  No sound in replays. Needs a graphics card (PC, not Kaggle). Shrink with
  `ffmpeg -i in.avi -c:v libx264 -crf 18 out.mp4`. The size comes from a one-off
  `override.cfg` the renderer deletes on start (Godot's Movie Maker ignores
  `--resolution`); the frame rate is passed as `--fixed-fps 30`.

## Game fixes made along the way

- **Hounds did no damage head-on:** their 2.1 m body stopped 1.45 m from the player,
  outside the 1.35 m hit reach. Touching the player during a charge now hits
  (1 hound hit in 90 s before the fix, 17 after, in the same idle test). This also
  changes human play.
- **Zombies spawned at the player's position** for a moment before moving to their
  spawn point, shoving the player about 0.6 m. They now get their position first.
  The player also starts at its standing height (0.5) instead of dropping from 1.01.

## Not tested yet

- Anything on Kaggle beyond the install step: Godot on Kaggle's Linux, the first
  asset import, real training speed, the evaluation and plot cells.
- The viewer and SAVE VIDEO on the Windows PC, and video export on screens smaller
  than 1280x720.
- Kill splits and the best-attempt comparison (no recorded game has kills yet).
- Whether the reward produces sensible behaviour: judge from the first real replays.

## Open decisions

- Reward tuning after watching real replays (e.g. reward for hits, or for causing
  collisions if that tactic is the video's hook; it won't appear on its own).
- Ammo resupply, or keep 60 rounds and let it learn to ration and run.
- Human reaction delay (~0.2 s) for fairness against people.
- Parallel games for speed, if the measured `fps` is too slow.
- Episode length (60 s now).

## Ideas for the YouTube video

- **Story arc from the data:** untrained flailing → stops walking off the roof →
  learns to shoot → learns to dodge hounds → survives full rounds. The attempts
  screen is the "progress over time" shot; pick early, middle and late attempts by
  training hours.
- **Show what it sees:** the input grid lighting up as zombies approach, the neuron
  blocks, the value strip dropping just before a hit.
- **Noise vs no noise:** the same model in training (noisy) and evaluation (clean)
  makes a good "practice vs real" segment.
- **Firsts:** first kill, first dodged charge, first full survival, first time
  zombies collide because of its movement.
- **Optionally compare with a human:** same rules (mouse aiming is human-limited).
- Videos come out silent; add game audio, music and narration in the editor.

## Working preferences (important for any agent)

- **Never open windows on this PC** (it's a friend's computer, used over SSH).
  Run Godot headless; for screenshots or video tests use a private Xvfb display
  (unpacked in the scratchpad without root).
- **No training on the local PC.** Local runs are short wiring tests only; real
  training is on Kaggle/Colab.
- **No "AI-looking" design:** no explanatory sentences, numbered section headers,
  disclaimers or generic dashboard styling. The viewer is a speedrun-style overlay
  with the Silkscreen pixel font, matching the PS1 game.
- **Commit and push only when asked** (the user says "push").
- The user prefers simple explanations and sometimes wants to code changes
  personally; earlier notes say not to restore the rejected sunset rooftop
  redesign and to show a reference before major environment redesigns.

## File map

| Path | Role |
| --- | --- |
| `game.tscn`, `survival.gd` | Playable game, spawning, HUD, kill/stat counters |
| `player___character_body_3d.gd` | Player, human/AI controls, virtual mouse, observations |
| `enemy_controller.gd`, `enemy_ragdoll.gd` | Zombies/hounds, charges, collisions, ragdolls, stat reports |
| `training.tscn`, `training/training_session.gd`, `training/zombie_rl_controller.gd` | Training scene, round resets, actions, reward |
| `training/zombie_env.py` | Gymnasium env, launches Godot, reward weights |
| `training/train.py`, `training/evaluate.py` | PPO training and noise-free evaluation |
| `training/recording.py`, `training/replay_format.py` | Recording format, numpy reader |
| `training/zombie_training.ipynb` | Kaggle/Colab notebook |
| `training/replay.tscn`, `training/replay_*.gd`, `brain_view.gd`, `inputs_view.gd`, `run_panel.gd`, `timeline_view.gd`, `progress_view.gd` | Replay viewer and video export |
| `training/smoke_test.py`, `training/smoke_test_replays.py` | Wiring tests (run after pipeline changes) |
| `fonts/silkscreen/` | Viewer font (OFL) |
| `docs/screenshots/` | Viewer screenshots (from untrained test data) |
