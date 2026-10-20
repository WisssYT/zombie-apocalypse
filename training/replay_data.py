"""Verify saved weights and reconstruct actual activations for Godot playback."""
from __future__ import annotations

from collections import OrderedDict
import gzip
import hashlib
import json
from pathlib import Path
import re

import gymnasium as gym
import numpy as np
from stable_baselines3.common.policies import ActorCriticPolicy
import torch

HERE = Path(__file__).resolve().parent


def resolve_run(path):
    path = Path(path).resolve()
    if (path / "manifest.json").is_file():
        return path
    candidates = list(path.glob("replays/*/manifest.json"))
    if not candidates:
        raise FileNotFoundError(f"No replay recordings in {path}. Train with replays enabled first.")
    return max(candidates, key=lambda item: item.stat().st_mtime).parent


class ReplayStore:
    def __init__(self, directory):
        self.directory = resolve_run(directory)
        self.policies = OrderedDict()
        self.episodes = OrderedDict()

    def index(self):
        return json.loads((self.directory / "index.json").read_text(encoding="utf-8"))

    def episode(self, identifier):
        if not re.fullmatch(r"episode-\d{6,}", identifier):
            raise ValueError("Invalid episode ID")
        path = self.directory / "episodes" / identifier
        stamp = path.with_suffix(".json.gz").stat().st_mtime_ns
        key = (identifier, stamp)
        if key not in self.episodes:
            with np.load(path.with_suffix(".npz"), allow_pickle=False) as archive:
                arrays = {name: archive[name] for name in archive.files}
            with gzip.open(path.with_suffix(".json.gz"), "rt", encoding="utf-8") as stream:
                metadata = json.load(stream)
            if len(metadata["frames"]) != len(arrays["observations"]):
                raise ValueError("Recording files are inconsistent; refresh after the write finishes")
            self.episodes[key] = (arrays, metadata)
            while len(self.episodes) > 2:
                self.episodes.popitem(last=False)
        self.episodes.move_to_end(key)
        return self.episodes[key]

    def policy(self, identifier):
        if not re.fullmatch(r"[0-9a-f]{64}", identifier):
            raise ValueError("Invalid policy ID")
        if identifier not in self.policies:
            path = self.directory / "policies" / f"{identifier}.pt"
            if hashlib.sha256(path.read_bytes()).hexdigest() != identifier:
                raise ValueError("Policy checksum failed. Refusing to display mismatched weights.")
            data = torch.load(path, map_location="cpu", weights_only=True)
            policy = ActorCriticPolicy(
                gym.spaces.Box(-1, 1, (586,), np.float32),
                gym.spaces.Box(-1, 1, (7,), np.float32), lambda _: 0.0,
                net_arch=data["net_arch"], activation_fn=torch.nn.Tanh)
            policy.load_state_dict(data["state_dict"], strict=True)
            policy.set_training_mode(False)
            self.policies[identifier] = (policy, data["timestep"])
            while len(self.policies) > 2:
                self.policies.popitem(last=False)
        self.policies.move_to_end(identifier)
        return self.policies[identifier]

    def frame(self, identifier, step):
        arrays, metadata = self.episode(identifier)
        if not 0 <= step < len(arrays["actions"]):
            raise ValueError("Terminal scene has no new neural decision; select an earlier step")
        policy_id = str(arrays["policy_ids"][step])
        policy, timestep = self.policy(policy_id)
        observation = torch.from_numpy(arrays["observations"][step:step + 1])
        action = torch.from_numpy(arrays["raw_actions"][step:step + 1])
        with torch.no_grad():
            features = policy.extract_features(observation)
            activations = {}
            for branch, network in (("actor", policy.mlp_extractor.policy_net),
                                    ("critic", policy.mlp_extractor.value_net)):
                current = features
                layers = []
                for module in network:
                    current = module(current)
                    if isinstance(module, torch.nn.Tanh):
                        layers.append(current[0].tolist())
                activations[branch] = layers
            distribution = policy.get_distribution(observation)
            value, log_prob, _ = policy.evaluate_actions(observation, action)
            value = value.item()
            log_prob = log_prob.item()
            mean = distribution.distribution.mean[0].tolist()
            std = distribution.distribution.stddev[0].tolist()
        recorded_value = float(arrays["values"][step])
        recorded_log_prob = float(arrays["log_probs"][step])
        value_error = abs(value - recorded_value)
        log_prob_error = abs(log_prob - recorded_log_prob)
        return {"observation": observation[0].tolist(), "activations": activations,
                "mean": mean, "std": std, "value": value,
                "recorded_value": recorded_value,
                "value_error": value_error, "log_prob_error": log_prob_error,
                "verified": value_error < 1e-5 and log_prob_error < 1e-5,
                "policy_id": policy_id, "policy_timestep": timestep,
                "action": arrays["actions"][step].tolist(),
                "raw_action": arrays["raw_actions"][step].tolist(),
                "reward": float(arrays["rewards"][step]), "step": step,
                "time": metadata["frames"][step]["time"]}

    def weights(self, identifier, branch, layer, neuron):
        policy, _ = self.policy(identifier)
        if branch not in ("actor", "critic") or not 0 <= layer <= 2:
            raise ValueError("Invalid network layer")
        network = policy.mlp_extractor.policy_net if branch == "actor" else policy.mlp_extractor.value_net
        layers = [module for module in network if isinstance(module, torch.nn.Linear)]
        layers.append(policy.action_net if branch == "actor" else policy.value_net)
        selected = layers[layer]
        if not 0 <= neuron < selected.out_features:
            raise ValueError("Invalid neuron")
        return {"weights": selected.weight[neuron].detach().tolist(),
                "bias": selected.bias[neuron].item(), "neuron": neuron,
                "layer": layer, "branch": branch}


    def export_episode(self, identifier, destination):
        arrays, metadata = self.episode(identifier)
        decisions = [self.frame(identifier, step) for step in range(len(arrays["actions"]))]
        policies = {}
        for policy_id in sorted(set(arrays["policy_ids"])):
            policy, timestep = self.policy(str(policy_id))
            branches = {}
            for branch, network, head in (
                ("actor", policy.mlp_extractor.policy_net, policy.action_net),
                ("critic", policy.mlp_extractor.value_net, policy.value_net),
            ):
                layers = [layer for layer in network if isinstance(layer, torch.nn.Linear)] + [head]
                branches[branch] = [{"weights": layer.weight.detach().tolist(),
                                     "biases": layer.bias.detach().tolist()} for layer in layers]
            policies[str(policy_id)] = branches
        data = {**metadata, "decisions": decisions, "policies": policies,
                "run": self.directory.name, "available_episodes": self.index()}
        destination = Path(destination)
        temporary = destination.with_suffix(destination.suffix + ".tmp")
        temporary.write_text(json.dumps(data, allow_nan=False, separators=(",", ":")), encoding="utf-8")
        temporary.replace(destination)
        return data
