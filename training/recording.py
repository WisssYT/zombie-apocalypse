"""Compressed episodes and exact policy versions, without video or rendered frames."""
from __future__ import annotations

from datetime import datetime, timezone
import gzip
import hashlib
import io
import json
from pathlib import Path
import platform
import uuid

import gymnasium as gym
import numpy as np
import stable_baselines3 as sb3
from stable_baselines3.common.callbacks import BaseCallback
import torch


def write_json(path, value):
    path = Path(path)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, allow_nan=False), encoding="utf-8")
    temporary.replace(path)


class EpisodeRecorder(gym.Wrapper):
    """One worker. Callback attaches the actual sampled action before flushing.

    Observations/scenes have T+1 entries. Decision t uses observation/scene t,
    and action t leads to scene t+1. A terminal observation is never replaced by
    the auto-reset observation. Policy IDs are per decision, not per episode.
    """

    def __init__(self, env, output, *, label="PPO TRAINING"):
        super().__init__(env)
        tag = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:6]
        self.directory = Path(output) / "replays" / tag
        self.label = label
        for name in ("episodes", "policies"):
            (self.directory / name).mkdir(parents=True, exist_ok=True)
        (self.directory / ".gdignore").touch()
        self.entries = {}
        self.sequence = 0
        self.current = None
        self.last_decision = None
        self.ready = []
        self.policy_id = None
        self.closed = False
        self.env.unwrapped.enable_replay()
        write_json(self.directory / "manifest.json", {
            "format": 1, "created_utc": tag, "observation_schema": 2,
            "observation_size": 586, "action_size": 7, "decision_hz": 15,
            "python": platform.python_version(), "torch": torch.__version__,
            "stable_baselines3": sb3.__version__, "numpy": np.__version__,
            "label": label,
            "recording": "Actual states and actions; no physics resimulation or video",
        })
        write_json(self.directory / "index.json", [])

    def reset(self, **kwargs):
        if self.current and self.current["actions"] and not self.current["complete"]:
            self._save(self.current, "interrupted")
        observation, info = self.env.reset(**kwargs)
        scene = info.pop("replay")
        self.current = {
            "id": f"episode-{self.sequence:06d}", "observations": [observation.copy()],
            "scenes": [scene], "actions": [], "raw_actions": [], "rewards": [],
            "values": [], "log_probs": [], "policy_ids": [], "terminated": [],
            "truncated": [], "complete": False, "seed": info.get("seed"),
            "game_episode_index": info.get("episode_index"), "final_info": info,
        }
        self.sequence += 1
        return observation, info

    def step(self, action):
        if self.policy_id is None:
            raise RuntimeError("Replay recording requires a saved policy before the first decision")
        obs, reward, terminated, truncated, info = self.env.step(action)
        scene = info.pop("replay")
        episode = self.current
        episode["observations"].append(obs.copy())
        episode["scenes"].append(scene)
        episode["actions"].append(np.asarray(action, np.float32).copy())
        episode["raw_actions"].append(np.full(7, np.nan, np.float32))
        episode["values"].append(np.nan)
        episode["log_probs"].append(np.nan)
        episode["policy_ids"].append(self.policy_id)
        episode["rewards"].append(reward)
        episode["terminated"].append(terminated)
        episode["truncated"].append(truncated)
        episode["final_info"] = dict(info)
        self.last_decision = (episode, len(episode["actions"]) - 1)
        if terminated or truncated:
            episode["complete"] = True
            self.ready.append(episode)
        return obs, reward, terminated, truncated, info

    def annotate_decision(self, raw_action, value, log_prob):
        episode, index = self.last_decision
        episode["raw_actions"][index] = np.asarray(raw_action, np.float32).copy()
        episode["values"][index] = float(value)
        episode["log_probs"][index] = float(log_prob)
        for completed in self.ready:
            self._save(completed, "complete")
        self.ready.clear()

    def save_policy(self, policy, timestep):
        # Only inference weights, shared by all decisions until the next update.
        # Full PPO optimizer/resume checkpoints are saved separately by train.py.
        if policy.net_arch != dict(pi=[128, 128], vf=[128, 128]) or policy.squash_output:
            raise ValueError("Replay format currently supports this project's 128x128 Tanh PPO policy")
        if not isinstance(policy.activation_fn(), torch.nn.Tanh):
            raise ValueError("Expected Tanh activation")
        payload = {"state_dict": {key: value.detach().cpu() for key, value in policy.state_dict().items()},
                   "net_arch": policy.net_arch, "timestep": timestep,
                   "observation_size": 586, "action_size": 7, "activation": "Tanh"}
        buffer = io.BytesIO()
        torch.save(payload, buffer)
        contents = buffer.getvalue()
        policy_id = hashlib.sha256(contents).hexdigest()
        path = self.directory / "policies" / f"{policy_id}.pt"
        if not path.exists():
            path.write_bytes(contents)
        self.policy_id = policy_id

    def _save(self, episode, status):
        if not episode["actions"]:
            return
        identifier = episode["id"]
        target = self.directory / "episodes" / identifier
        arrays = {
            "observations": np.asarray(episode["observations"], np.float32),
            "actions": np.asarray(episode["actions"], np.float32),
            "raw_actions": np.asarray(episode["raw_actions"], np.float32),
            "rewards": np.asarray(episode["rewards"], np.float32),
            "values": np.asarray(episode["values"], np.float32),
            "log_probs": np.asarray(episode["log_probs"], np.float32),
            "policy_ids": np.asarray(episode["policy_ids"], dtype="U64"),
            "terminated": np.asarray(episode["terminated"], bool),
            "truncated": np.asarray(episode["truncated"], bool),
        }
        with target.with_suffix(".npz.tmp").open("wb") as stream:
            np.savez_compressed(stream, **arrays)
        target.with_suffix(".npz.tmp").replace(target.with_suffix(".npz"))
        metadata = {key: episode[key] for key in ("id", "seed", "game_episode_index")}
        metadata.update(status=status, frames=episode["scenes"], final_info=episode["final_info"])
        metadata["label"] = self.label
        with gzip.open(target.with_suffix(".json.gz.tmp"), "wt", encoding="utf-8") as stream:
            json.dump(metadata, stream, allow_nan=False, separators=(",", ":"))
        target.with_suffix(".json.gz.tmp").replace(target.with_suffix(".json.gz"))
        final = episode["scenes"][-1]
        entry = {"id": identifier, "status": status, "steps": len(episode["actions"]),
                 "seconds": final["time"], "kills": final["kills"], "health": final["health"],
                 "reward": sum(episode["rewards"]),
                 "bytes": target.with_suffix(".npz").stat().st_size + target.with_suffix(".json.gz").stat().st_size}
        self.entries[identifier] = entry
        write_json(self.directory / "index.json", list(self.entries.values()))

    def flush_partial(self, status="in_progress"):
        if self.current and not self.current["complete"]:
            self._save(self.current, status)

    def close(self):
        if self.closed:
            return
        self.closed = True
        try:
            for completed in self.ready:
                self._save(completed, "complete")
            self.ready.clear()
            self.flush_partial("interrupted")
        finally:
            self.env.close()


class ReplayCallback(BaseCallback):
    def __init__(self, recorder):
        super().__init__()
        self.recorder = recorder

    def _on_rollout_start(self):
        # PPO freezes weights while collecting a rollout. Episodes may cross
        # updates, so each individual decision stores its own policy ID.
        self.recorder.save_policy(self.model.policy, self.model.num_timesteps)

    def _on_step(self):
        self.recorder.annotate_decision(
            self.locals["actions"][0], self.locals["values"][0].item(),
            self.locals["log_probs"][0].item())
        return True

    def _on_rollout_end(self):
        self.recorder.flush_partial()
