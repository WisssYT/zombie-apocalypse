"""Play a trained model with its exploration noise off, on rounds it never trained on.

During training PPO adds deliberate random noise to every action so it keeps
trying new things. Evaluation turns that off: the network always does its most
likely action (the mean). Games are recorded next to the training games, marked
as evaluation, so the viewer can replay them.
"""
import argparse
from pathlib import Path

import numpy as np
from stable_baselines3 import PPO
import torch

from recording import EpisodeRecorder
from train import latest_model
from zombie_env import ZombieEnv

# Training uses round seeds 1, 2, 3...; evaluation starts far away from them.
EVALUATION_SEED = 1_000_000


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", default="latest", help="A model .zip, or 'latest' in --output")
    parser.add_argument("--games", type=int, default=10)
    parser.add_argument("--episode-seconds", type=float, default=60)
    parser.add_argument("--seed", type=int, default=EVALUATION_SEED)
    parser.add_argument("--godot")
    parser.add_argument("--port", type=int, default=11010, help="Differs from training so both can run")
    parser.add_argument("--output", type=Path, default=Path(__file__).parent / "runs/ppo")
    parser.add_argument("--no-replays", action="store_true")
    args = parser.parse_args()
    model_path = latest_model(args.output) if args.model == "latest" else Path(args.model)
    if model_path is None:
        parser.error(f"No model found in {args.output}")
    torch.set_num_threads(1)
    model = PPO.load(model_path, device="cpu")
    print(f"Evaluating {model_path} ({model.num_timesteps} training steps), noise off")
    game = ZombieEnv(godot=args.godot, seed=args.seed, port=args.port,
                     episode_seconds=args.episode_seconds)
    env = game if args.no_replays else EpisodeRecorder(
        game, args.output, label="Evaluation, no noise", mode="evaluation")
    results = []
    try:
        if not args.no_replays:
            env.save_policy(model.policy, model.num_timesteps)
        for number in range(args.games):
            obs, _ = env.reset()
            done = False
            while not done:
                with torch.no_grad():
                    actions, values, log_probs = model.policy(torch.as_tensor(obs[None]), deterministic=True)
                raw = actions.numpy()[0]
                obs, _, terminated, truncated, info = env.step(np.clip(raw, -1.0, 1.0))
                if not args.no_replays:
                    env.annotate_decision(raw, values.item(), log_probs.item(), model.num_timesteps)
                done = terminated or truncated
            results.append(info)
            print(f"game {number + 1}: {info['elapsed']:.1f}s, {info['kills']} kills, "
                  f"{info['collisions']} collisions, {info['fell_off']} fell off, "
                  f"{'died' if info['terminated'] else 'survived'}")
    finally:
        env.close()
    if results:
        survived = sum(not r["terminated"] for r in results)
        print(f"\n{len(results)} games: survived {survived}, "
              f"average {np.mean([r['elapsed'] for r in results]):.1f}s, "
              f"{np.mean([r['kills'] for r in results]):.1f} kills, "
              f"{np.mean([r['collisions'] for r in results]):.1f} collisions, "
              f"{np.mean([r['fell_off'] for r in results]):.1f} fell off")
        if not args.no_replays:
            print(f"Recorded to {env.directory}")


if __name__ == "__main__":
    main()
