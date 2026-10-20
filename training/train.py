"""Single-instance PPO entry point; intended for Colab/Kaggle after smoke checks."""
import argparse
from pathlib import Path

from stable_baselines3 import PPO
from stable_baselines3.common.callbacks import CheckpointCallback
from stable_baselines3.common.monitor import Monitor
from zombie_env import ZombieEnv
from recording import EpisodeRecorder, ReplayCallback


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot")
    parser.add_argument("--steps", type=int, default=100_000)
    parser.add_argument("--episode-seconds", type=float, default=60)
    parser.add_argument("--show", action="store_true")
    parser.add_argument("--no-replays", action="store_true", help="Disable state/brain recording")
    parser.add_argument("--resume", type=Path)
    parser.add_argument("--output", type=Path, default=Path(__file__).parent / "runs/ppo")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    game = ZombieEnv(godot=args.godot, show_window=args.show,
                     episode_seconds=args.episode_seconds)
    recorder = None if args.no_replays else EpisodeRecorder(game, args.output)
    env = Monitor(recorder if recorder is not None else game, str(args.output / "episodes"))
    try:
        if args.resume:
            model = PPO.load(args.resume, env=env, device="cpu")
        else:
            model = PPO("MlpPolicy", env, device="cpu", seed=1, verbose=1,
                        n_steps=256, batch_size=64,
                        policy_kwargs=dict(net_arch=dict(pi=[128, 128], vf=[128, 128])))
        callbacks = [CheckpointCallback(save_freq=10_000,
                                        save_path=str(args.output / "checkpoints"))]
        if recorder is not None:
            print(f"State/brain replays: {recorder.directory}")
            callbacks.append(ReplayCallback(recorder))
        model.learn(args.steps, reset_num_timesteps=not bool(args.resume), callback=callbacks)
        model.save(args.output / "survivor")
    finally:
        env.close()


if __name__ == "__main__":
    main()
