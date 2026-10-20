"""Small local integration check, not a survival-training experiment."""
import argparse
import subprocess
import sys

import numpy as np
from stable_baselines3 import PPO
from stable_baselines3.common.monitor import Monitor
import torch

from recording import EpisodeRecorder, ReplayCallback
from replay_data import ReplayStore
from zombie_env import ZombieEnv, PROJECT


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot")
    args = parser.parse_args()
    torch.set_num_threads(1)
    game = ZombieEnv(godot=args.godot, episode_seconds=6)
    godot = game.godot
    recorder = EpisodeRecorder(game, PROJECT / "training/runs/replay-smoke",
                               label="PIPELINE CHECK / NOT A TRAINED SURVIVOR")
    env = Monitor(recorder)
    try:
        model = PPO("MlpPolicy", env, seed=12, device="cpu", verbose=0,
                    n_steps=32, batch_size=32, n_epochs=1,
                    policy_kwargs=dict(net_arch=dict(pi=[128, 128], vf=[128, 128])))
        # Four short collection/update cycles exercise a round crossing updates.
        model.learn(128, callback=ReplayCallback(recorder))
    finally:
        env.close()
    store = ReplayStore(recorder.directory)
    entries = store.index()
    assert any(entry["status"] == "complete" for entry in entries)
    assert any(entry["status"] == "interrupted" for entry in entries)
    count = 0
    for entry in entries:
        arrays, metadata = store.episode(entry["id"])
        steps = len(arrays["actions"])
        assert arrays["observations"].shape == (steps + 1, 586)
        assert len(metadata["frames"]) == steps + 1
        np.testing.assert_array_equal(np.clip(arrays["raw_actions"], -1, 1), arrays["actions"])
        for step in range(steps):
            result = store.frame(entry["id"], step)
            assert result["verified"], result
            assert len(result["activations"]["actor"]) == 2
            assert len(result["activations"]["critic"][0]) == 128
            assert len(result["observation"]) == 586
            count += 1
        if entry["status"] == "complete":
            assert arrays["terminated"][-1] or arrays["truncated"][-1]
            assert len(set(arrays["policy_ids"])) > 1
        temporary = recorder.directory / "check-playback.json"
        store.export_episode(entry["id"], temporary)
        try:
            command = [godot, "--headless", "--path", str(PROJECT),
                       "res://training/replay.tscn", "--", f"--replay-file={temporary}", "--replay-check"]
            result = subprocess.run(command, capture_output=True, text=True, timeout=60)
            assert result.returncode == 0 and "REPLAY_CHECK_OK" in result.stdout, result.stdout + result.stderr
            assert "SCRIPT ERROR" not in result.stderr and "ERROR:" not in result.stderr, result.stderr
        finally:
            temporary.unlink(missing_ok=True)
    weights = store.weights(str(arrays["policy_ids"][0]), "actor", 0, 0)
    assert len(weights["weights"]) == 586
    temporary = recorder.directory / "check-switch.json"
    try:
        store.export_episode(entries[0]["id"], temporary)
        result = subprocess.run([
            godot, "--headless", "--path", str(PROJECT), "res://training/replay.tscn", "--",
            f"--replay-file={temporary}", f"--python-bin={sys.executable}",
            f"--archive-path={recorder.directory}", "--replay-switch-check"],
            capture_output=True, text=True, timeout=60)
        assert result.returncode == 0 and "EPISODE_SWITCH_OK" in result.stdout, result.stdout + result.stderr
        assert "ERROR:" not in result.stderr, result.stderr
    finally:
        temporary.unlink(missing_ok=True)
    # A changed checkpoint is rejected, rather than quietly showing another brain.
    policy_id = str(arrays["policy_ids"][0])
    policy_path = recorder.directory / "policies" / f"{policy_id}.pt"
    original = policy_path.read_bytes()
    try:
        policy_path.write_bytes(original + b"corruption")
        store.policies.clear()
        try:
            store.policy(policy_id)
        except ValueError as error:
            assert "checksum" in str(error)
        else:
            raise AssertionError("Corrupted weights were accepted")
    finally:
        policy_path.write_bytes(original)
    bytes_total = sum(path.stat().st_size for path in recorder.directory.rglob("*") if path.is_file())
    print(f"PASS: {count} actual decisions, exact actor/critic inference and sampled actions")
    print("PASS: complete/partial rounds, policy changes within a round, checksum rejection, Godot model playback")
    print(f"Replay archive: {recorder.directory}\nTotal archive bytes (including weights): {bytes_total}")


if __name__ == "__main__":
    main()
