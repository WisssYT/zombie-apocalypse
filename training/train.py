"""Single-instance PPO entry point, meant to run on Kaggle/Colab (see notebook)."""
import argparse
import math
from pathlib import Path
import time

from stable_baselines3 import PPO
from stable_baselines3.common.callbacks import BaseCallback, CheckpointCallback
from stable_baselines3.common.monitor import Monitor
from zombie_env import ZombieEnv
from recording import EpisodeRecorder, ReplayCallback


class TimeBudget(BaseCallback):
    """Stops cleanly before a notebook session is killed, so nothing is lost."""

    def __init__(self, hours):
        super().__init__()
        self.deadline = time.monotonic() + hours * 3600

    def _on_step(self):
        return time.monotonic() < self.deadline


def latest_model(output):
    candidates = list((output / "checkpoints").glob("*.zip")) + list(output.glob("survivor.zip"))
    return max(candidates, key=lambda path: path.stat().st_mtime, default=None)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot")
    parser.add_argument("--steps", type=int, default=100_000)
    parser.add_argument("--hours", type=float, help="Stop and save after this much wall time")
    parser.add_argument("--episode-seconds", type=float, default=60)
    parser.add_argument("--n-steps", type=int, default=2048,
                        help="Decisions per PPO rollout; one weight snapshot is recorded per rollout")
    parser.add_argument("--noise", type=float, default=1.0,
                        help="Starting exploration noise (action std); PPO then learns its own")
    parser.add_argument("--show", action="store_true")
    parser.add_argument("--no-replays", action="store_true", help="Disable episode recording")
    parser.add_argument("--resume", help="A model .zip, or 'latest' for the newest one in --output")
    parser.add_argument("--output", type=Path, default=Path(__file__).parent / "runs/ppo")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    resume = latest_model(args.output) if args.resume == "latest" else args.resume
    game = ZombieEnv(godot=args.godot, show_window=args.show,
                     episode_seconds=args.episode_seconds)
    recorder = None if args.no_replays else EpisodeRecorder(game, args.output)
    env = Monitor(recorder if recorder is not None else game,
                  str(args.output / f"episodes-{int(time.time())}"),
                  info_keywords=("kills", "collisions", "hound_knockdowns", "tripped", "fell_off"))
    try:
        if resume:
            print(f"Resuming from {resume}")
            model = PPO.load(resume, env=env, device="cpu")
        else:
            model = PPO("MlpPolicy", env, device="cpu", seed=1, verbose=1,
                        n_steps=args.n_steps, batch_size=64,
                        policy_kwargs=dict(net_arch=dict(pi=[128, 128], vf=[128, 128]),
                                           log_std_init=math.log(args.noise)))
        callbacks = [CheckpointCallback(save_freq=10_000,
                                        save_path=str(args.output / "checkpoints"))]
        if args.hours:
            callbacks.append(TimeBudget(args.hours))
        if recorder is not None:
            print(f"Recording every episode to {recorder.directory}")
            callbacks.append(ReplayCallback(recorder))
        model.learn(args.steps, reset_num_timesteps=not resume, callback=callbacks)
        model.save(args.output / "survivor")
    finally:
        env.close()


if __name__ == "__main__":
    main()
