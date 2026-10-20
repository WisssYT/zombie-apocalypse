"""Read recorded episodes with numpy only (no torch) and rerun the saved network.

The Godot viewer does the same forward pass in GDScript; this copy lets tests and
the notebook check that recorded weights reproduce the live values exactly.
"""
from __future__ import annotations

import gzip
import hashlib
import json
from pathlib import Path

import numpy as np


def sessions(root):
    """Every recording session under a run folder, oldest first."""
    root = Path(root)
    if (root / "manifest.json").is_file():
        return [root]
    return sorted(path.parent for path in root.glob("**/replays/*/manifest.json"))


def load_policy(session, policy_id):
    session = Path(session)
    contents = (session / "policies" / f"{policy_id}.bin").read_bytes()
    if hashlib.sha256(contents).hexdigest() != policy_id:
        raise ValueError(f"Weights {policy_id[:12]} fail their checksum")
    manifest = json.loads((session / "manifest.json").read_text(encoding="utf-8"))
    values = np.frombuffer(contents, "<f4")
    tensors, offset = {}, 0
    for layer in manifest["policy_layout"]:
        count = int(np.prod(layer["shape"]))
        tensors[layer["name"]] = values[offset:offset + count].reshape(layer["shape"])
        offset += count
    if offset != values.size:
        raise ValueError("Weight file size does not match the manifest layout")
    return tensors


def load_episode(session, identifier):
    path = Path(session) / "episodes" / identifier
    metadata = json.loads(gzip.decompress(path.with_suffix(".json.gz").read_bytes()))
    flat = np.frombuffer(gzip.decompress(path.with_suffix(".bin.gz").read_bytes()), "<f4")
    arrays, offset = {}, 0
    for entry in metadata["arrays"]:
        count = int(np.prod(entry["shape"]))
        arrays[entry["name"]] = flat[offset:offset + count].reshape(entry["shape"])
        offset += count
    if offset != flat.size or len(metadata["frames"]) != metadata["steps"] + 1:
        raise ValueError(f"{identifier} is inconsistent; it may still be being written")
    policy_ids = []
    runs = metadata["policy_runs"] + [[metadata["steps"], None]]
    for (start, policy_id), (end, _) in zip(runs, runs[1:]):
        policy_ids += [policy_id] * (end - start)
    arrays["policy_ids"] = policy_ids
    return arrays, metadata


def forward(tensors, observation):
    """Hidden activations, action means/std and value, exactly as SB3 computes them."""
    result = {}
    for branch in ("actor", "critic"):
        h1 = np.tanh(observation @ tensors[f"{branch}.0.weight"] + tensors[f"{branch}.0.bias"])
        h2 = np.tanh(h1 @ tensors[f"{branch}.1.weight"] + tensors[f"{branch}.1.bias"])
        result[branch] = (h1, h2, h2 @ tensors[f"{branch}.out.weight"] + tensors[f"{branch}.out.bias"])
    return {"actor_hidden": result["actor"][:2], "critic_hidden": result["critic"][:2],
            "mean": result["actor"][2], "std": np.exp(tensors["actor.log_std"]),
            "value": result["critic"][2][..., 0]}


def log_prob(mean, std, action):
    return np.sum(-((action - mean) ** 2) / (2 * std ** 2) - np.log(std) - 0.5 * np.log(2 * np.pi), axis=-1)
