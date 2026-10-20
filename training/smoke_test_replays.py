"""Small integration check of recording + Godot playback, not a training experiment."""
import argparse
from pathlib import Path
import subprocess

import numpy as np
from stable_baselines3 import PPO
from stable_baselines3.common.monitor import Monitor
import torch

from recording import EpisodeRecorder, ReplayCallback
from replay_format import forward, load_episode, load_policy, log_prob
from zombie_env import ZombieEnv, PROJECT


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot")
    parser.add_argument("--steps", type=int, default=128)
    parser.add_argument("--episode-seconds", type=float, default=6)
    parser.add_argument("--output", type=Path, default=PROJECT / "training/runs/replay-smoke")
    args = parser.parse_args()
    torch.set_num_threads(1)
    game = ZombieEnv(godot=args.godot, episode_seconds=args.episode_seconds)
    godot = game.godot
    recorder = EpisodeRecorder(game, args.output, label="Pipeline check, untrained")
    env = Monitor(recorder)
    try:
        model = PPO("MlpPolicy", env, seed=12, device="cpu", verbose=0,
                    n_steps=32, batch_size=32, n_epochs=1,
                    policy_kwargs=dict(net_arch=dict(pi=[128, 128], vf=[128, 128])))
        # Several short collection/update cycles make a round cross updates.
        model.learn(args.steps, callback=ReplayCallback(recorder))
    finally:
        env.close()
    session = recorder.directory
    import json
    entries = json.loads((session / "index.json").read_text())
    statuses = {entry["status"] for entry in entries}
    assert statuses & {"died", "timeout"} and "interrupted" in statuses, statuses
    decisions = 0
    for entry in entries:
        arrays, metadata = load_episode(session, entry["id"])
        steps = metadata["steps"]
        assert arrays["observations"].shape == (steps + 1, 590)
        np.testing.assert_array_equal(np.clip(arrays["raw_actions"], -1, 1), arrays["actions"])
        for step in range(steps):
            net = forward(load_policy(session, arrays["policy_ids"][step]), arrays["observations"][step])
            assert abs(net["value"] - arrays["values"][step]) < 1e-4
            assert abs(log_prob(net["mean"], net["std"], arrays["raw_actions"][step])
                       - arrays["log_probs"][step]) < 1e-3
            decisions += 1
        if entry["status"] != "interrupted":
            assert len(metadata["policy_runs"]) > 1, "expected a round crossing a PPO update"
    policy_id = arrays["policy_ids"][0]
    path = session / "policies" / f"{policy_id}.bin"
    original = path.read_bytes()
    try:
        path.write_bytes(original + b"\0\0\0\0")
        try:
            load_policy(session, policy_id)
        except ValueError as error:
            assert "checksum" in str(error)
        else:
            raise AssertionError("Corrupted weights were accepted")
    finally:
        path.write_bytes(original)
    result = subprocess.run(
        [godot, "--headless", "--path", str(PROJECT), "res://training/replay.tscn", "--",
         f"--run={session}", "--check"], capture_output=True, text=True, timeout=300)
    output = result.stdout + result.stderr
    assert result.returncode == 0 and "REPLAY_CHECK_OK" in result.stdout, output
    # Headless Godot's dummy renderer reports this when models are freed; real rendering doesn't.
    errors = [line for line in output.splitlines() if "ERROR" in line
              and 'Parameter "material" is null' not in line]
    assert not errors, output
    total = sum(p.stat().st_size for p in session.rglob("*") if p.is_file())
    print(f"PASS: {decisions} decisions reproduced from saved weights (numpy)")
    print("PASS: " + result.stdout.strip().splitlines()[-1])
    print(f"Archive {session}: {len(entries)} episodes, {total / 1e6:.2f} MB")


if __name__ == "__main__":
    main()
