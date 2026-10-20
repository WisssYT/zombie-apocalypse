"""Verify one real Godot instance before spending time on training."""
import argparse
import numpy as np
from zombie_env import ZombieEnv


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot")
    parser.add_argument("--show", action="store_true")
    args = parser.parse_args()
    env = ZombieEnv(godot=args.godot, show_window=args.show, episode_seconds=2)
    try:
        obs, _ = env.reset(seed=1)
        assert obs.shape == (590,) and env.observation_space.contains(obs)
        assert obs[0] == 1 and obs[1] == 1 and obs[23] == 0
        print("PASS: 590 observations, fresh health/ammunition")
        start_x = obs[5]
        action = np.array([1, 0, 1, 0, 1, -1, -1], np.float32)
        for _ in range(3):
            obs, _, terminated, truncated, info = env.step(action)
            assert not terminated and not truncated
        assert obs[5] > start_x and info["ammo"] < 12
        print("PASS: Python movement/mouse/shoot commands affect the game")
        action[:] = [0, 0, 1, 0, -1, 1, -1]
        _, _, _, _, info = env.step(action)
        assert info["reloading"]
        action[:] = [1, 0, 1, 0, 1, -1, 1]
        before_ammo = info["ammo"]
        _, _, _, _, info = env.step(action)
        assert info["dashing"] and not info["reloading"] and info["ammo"] == before_ammo
        print("PASS: reload, dash cancellation and dash firing restrictions")
        action[:] = [0, 0, 1, 0, -1, -1, -1]
        while not (terminated or truncated):
            obs, reward, terminated, truncated, info = env.step(action)
            assert np.isfinite(reward)
        assert truncated and not terminated and obs[23] == 0
        print("PASS: time limit is truncation, with final observation retained")
        obs, _ = env.reset(seed=1)
        assert obs[0] == 1 and obs[1] == 1 and obs[23] == 0
        assert np.all(obs[32:] == 0) and obs[30] == 0 and obs[31] == 0
        print("PASS: reset clears enemies and restores the player")
        # Aim goes through a virtual mouse: speed builds up, then the cursor
        # stops at the edge of the screen, like a real one.
        action[:] = [0, 0, 1, 0, -1, -1, -1]
        speeds = []
        for _ in range(4):
            obs, _, _, _, _ = env.step(action)
            speeds.append(obs[30])
        assert 0 < speeds[0] < speeds[1] == 1, speeds  # ~0.1 s to full speed, not instant
        for _ in range(20):
            obs, _, _, _, _ = env.step(action)
        assert abs(obs[5] * 16 + obs[28] * 32 - 22) < 0.01 and obs[30] == 0
        print("PASS: aiming moves a cursor with human speed limits, kept on screen")
    finally:
        env.close()
    # A longer episode lets deliberate movement off the roof exercise real death.
    env = ZombieEnv(godot=args.godot, show_window=args.show, episode_seconds=30)
    try:
        env.reset(seed=1)
        action = np.array([1, 0, 1, 0, -1, -1, -1], np.float32)
        for _ in range(200):
            obs, reward, terminated, truncated, info = env.step(action)
            if terminated or truncated:
                break
        assert terminated and not truncated and obs[23] == 1
        assert info["health"] == 0 and reward < 0
        print("PASS: real death is termination, with death penalty/final state")
        obs, _ = env.reset()
        assert obs[23] == 0 and obs[0] == 1 and obs[1] == 1
        print("PASS: a fresh round starts on the same connection after death")
    finally:
        env.close()
    print("Single-instance pipeline checks passed.")


if __name__ == "__main__":
    main()
