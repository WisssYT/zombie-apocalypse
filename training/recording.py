"""Records every training episode so it can be rewatched later in Godot.

Nothing here is a video. Each episode keeps the sampled world state (for the 3D
playback), the exact observations/actions, and which weight snapshot chose each
action. Weights are stored once per PPO rollout as raw float32, so the Godot
viewer recomputes every neuron itself and the viewing PC needs no Python.

Archive layout (one folder per training session, sessions never overwrite):

    replays/<session>/manifest.json         formats, layer layout, field names
    replays/<session>/policies.json         [{id, timestep}] in training order
    replays/<session>/policies/<id>.bin     float32 weights, id = sha256 of bytes
    replays/<session>/index.json            one summary row per episode
    replays/<session>/episodes/<ep>.json.gz world frames, metadata, array layout
    replays/<session>/episodes/<ep>.bin.gz  float32 observations/actions/values
"""
from __future__ import annotations

from datetime import datetime, timezone
import gzip
import hashlib
import json
from pathlib import Path
import platform
import uuid

import gymnasium as gym
import numpy as np
import stable_baselines3 as sb3
from stable_baselines3.common.callbacks import BaseCallback
import torch

FORMAT = 2
OBSERVATION_SIZE = 586
ACTION_SIZE = 7
HIDDEN = 128
# Every matrix is stored input-major (in x out), the order the viewer multiplies in.
POLICY_LAYOUT = [
    ("actor.0.weight", [OBSERVATION_SIZE, HIDDEN]), ("actor.0.bias", [HIDDEN]),
    ("actor.1.weight", [HIDDEN, HIDDEN]), ("actor.1.bias", [HIDDEN]),
    ("actor.out.weight", [HIDDEN, ACTION_SIZE]), ("actor.out.bias", [ACTION_SIZE]),
    ("actor.log_std", [ACTION_SIZE]),
    ("critic.0.weight", [OBSERVATION_SIZE, HIDDEN]), ("critic.0.bias", [HIDDEN]),
    ("critic.1.weight", [HIDDEN, HIDDEN]), ("critic.1.bias", [HIDDEN]),
    ("critic.out.weight", [HIDDEN, 1]), ("critic.out.bias", [1]),
]


def write_json(path, value):
    path = Path(path)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, allow_nan=False), encoding="utf-8")
    temporary.replace(path)


def write_bytes(path, contents):
    path = Path(path)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_bytes(contents)
    temporary.replace(path)


def policy_tensors(policy):
    """SB3 MlpPolicy tensors in POLICY_LAYOUT order."""
    actor = [m for m in policy.mlp_extractor.policy_net if isinstance(m, torch.nn.Linear)]
    critic = [m for m in policy.mlp_extractor.value_net if isinstance(m, torch.nn.Linear)]
    tensors = []
    for layers, head in ((actor, policy.action_net), (critic, policy.value_net)):
        for linear in layers + [head]:
            tensors += [linear.weight.T, linear.bias]
        if head is policy.action_net:
            tensors.append(policy.log_std)
    return [t.detach().cpu().numpy().astype("<f4") for t in tensors]


class EpisodeRecorder(gym.Wrapper):
    """One worker. The callback attaches the actual sampled action before saving.

    Observations/frames have T+1 entries. Decision t uses observation/frame t,
    and action t leads to frame t+1. A terminal observation is never replaced by
    the auto-reset observation. Policy IDs are per decision, not per episode,
    because a long episode can cross several PPO updates.
    """

    def __init__(self, env, output, *, label="PPO training"):
        super().__init__(env)
        tag = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:6]
        self.directory = Path(output) / "replays" / tag
        self.label = label
        for name in ("episodes", "policies"):
            (self.directory / name).mkdir(parents=True, exist_ok=True)
        (self.directory / ".gdignore").touch()
        self.entries = {}
        self.policy_list = []
        self.sequence = 0
        self.current = None
        self.last_decision = None
        self.ready = []
        self.policy_id = None
        self.timestep = 0
        self.closed = False
        self.env.unwrapped.enable_replay()
        write_json(self.directory / "manifest.json", {
            "format": FORMAT, "session": tag, "label": label,
            "observation_schema": 2, "observation_size": OBSERVATION_SIZE,
            "action_size": ACTION_SIZE, "decision_hz": 15, "activation": "tanh",
            "policy_layout": [{"name": n, "shape": s} for n, s in POLICY_LAYOUT],
            "python": platform.python_version(), "torch": torch.__version__,
            "stable_baselines3": sb3.__version__, "numpy": np.__version__,
        })
        write_json(self.directory / "policies.json", [])
        write_json(self.directory / "index.json", [])

    def reset(self, **kwargs):
        if self.current and self.current["actions"] and not self.current["complete"]:
            self._save(self.current, "interrupted")
        observation, info = self.env.reset(**kwargs)
        scene = info.pop("replay")
        self.current = {
            "id": f"episode-{self.sequence:06d}", "observations": [observation.copy()],
            "scenes": [scene], "actions": [], "raw_actions": [], "rewards": [],
            "values": [], "log_probs": [], "policy_ids": [], "complete": False,
            "ending": None, "seed": info.get("seed"),
            "game_episode_index": info.get("episode_index"),
            "timestep_start": self.timestep, "timestep_end": self.timestep,
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
        episode["raw_actions"].append(np.full(ACTION_SIZE, np.nan, np.float32))
        episode["values"].append(np.nan)
        episode["log_probs"].append(np.nan)
        episode["policy_ids"].append(self.policy_id)
        episode["rewards"].append(reward)
        self.last_decision = (episode, len(episode["actions"]) - 1)
        if terminated or truncated:
            episode["complete"] = True
            episode["ending"] = "died" if terminated else "timeout"
            self.ready.append(episode)
        return obs, reward, terminated, truncated, info

    def annotate_decision(self, raw_action, value, log_prob, timestep):
        episode, index = self.last_decision
        episode["raw_actions"][index] = np.asarray(raw_action, np.float32).copy()
        episode["values"][index] = float(value)
        episode["log_probs"][index] = float(log_prob)
        episode["timestep_end"] = self.timestep = timestep
        for completed in self.ready:
            self._save(completed, completed["ending"])
        self.ready.clear()

    def save_policy(self, policy, timestep):
        # Inference weights only, shared by every decision until the next update.
        # Full PPO optimizer/resume checkpoints are saved separately by train.py.
        if policy.net_arch != dict(pi=[HIDDEN, HIDDEN], vf=[HIDDEN, HIDDEN]) or policy.squash_output:
            raise ValueError("Replay format supports this project's 128x128 Tanh PPO policy")
        if not isinstance(policy.activation_fn(), torch.nn.Tanh):
            raise ValueError("Expected Tanh activation")
        tensors = policy_tensors(policy)
        for tensor, (name, shape) in zip(tensors, POLICY_LAYOUT):
            if list(tensor.shape) != shape:
                raise ValueError(f"{name} has shape {tensor.shape}, expected {shape}")
        contents = b"".join(np.ascontiguousarray(t).tobytes() for t in tensors)
        policy_id = hashlib.sha256(contents).hexdigest()
        path = self.directory / "policies" / f"{policy_id}.bin"
        if not path.exists():
            write_bytes(path, contents)
            self.policy_list.append({"id": policy_id, "timestep": timestep})
            write_json(self.directory / "policies.json", self.policy_list)
        self.policy_id = policy_id
        self.timestep = timestep

    def _save(self, episode, status):
        if not episode["actions"]:
            return
        identifier = episode["id"]
        target = self.directory / "episodes" / identifier
        arrays = {
            "observations": np.asarray(episode["observations"], "<f4"),
            "actions": np.asarray(episode["actions"], "<f4"),
            "raw_actions": np.asarray(episode["raw_actions"], "<f4"),
            "rewards": np.asarray(episode["rewards"], "<f4"),
            "values": np.asarray(episode["values"], "<f4"),
            "log_probs": np.asarray(episode["log_probs"], "<f4"),
        }
        runs = []
        for step, policy_id in enumerate(episode["policy_ids"]):
            if not runs or runs[-1][1] != policy_id:
                runs.append([step, policy_id])
        write_bytes(target.with_suffix(".bin.gz"), gzip.compress(
            b"".join(a.tobytes() for a in arrays.values()), compresslevel=6))
        final = episode["scenes"][-1]
        metadata = {
            "format": FORMAT, "id": identifier, "status": status, "label": self.label,
            "seed": episode["seed"], "game_episode_index": episode["game_episode_index"],
            "timestep_start": episode["timestep_start"], "timestep_end": episode["timestep_end"],
            "steps": len(episode["actions"]),
            "arrays": [{"name": n, "shape": list(a.shape)} for n, a in arrays.items()],
            "policy_runs": runs, "frames": episode["scenes"],
        }
        write_bytes(target.with_suffix(".json.gz"), gzip.compress(
            json.dumps(metadata, allow_nan=False, separators=(",", ":")).encode("utf-8"),
            compresslevel=6))
        self.entries[identifier] = {
            "id": identifier, "status": status, "steps": len(episode["actions"]),
            "seconds": final["time"], "kills": final["kills"], "health": final["health"],
            "reward": float(sum(episode["rewards"])),
            "timestep": episode["timestep_end"],
            "bytes": sum(target.with_suffix(s).stat().st_size for s in (".bin.gz", ".json.gz")),
        }
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
                self._save(completed, completed["ending"])
            self.ready.clear()
            self.flush_partial("interrupted")
        finally:
            self.env.close()


class ReplayCallback(BaseCallback):
    def __init__(self, recorder):
        super().__init__()
        self.recorder = recorder

    def _on_rollout_start(self):
        # PPO freezes weights while collecting a rollout.
        self.recorder.save_policy(self.model.policy, self.model.num_timesteps)

    def _on_step(self):
        self.recorder.annotate_decision(
            self.locals["actions"][0], self.locals["values"][0].item(),
            self.locals["log_probs"][0].item(), self.model.num_timesteps)
        return True

    def _on_rollout_end(self):
        self.recorder.flush_partial()
