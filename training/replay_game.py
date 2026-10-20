"""Watch a recorded episode with the original Godot assets; no physics rerun."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import sys

from replay_data import ReplayStore, resolve_run
from zombie_env import DEFAULT_GODOT, PROJECT
import os
import torch


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, default=PROJECT / "training/runs/ppo")
    parser.add_argument("--episode", help="For example episode-000003; defaults to the last saved episode")
    parser.add_argument("--godot", default=os.environ.get("GODOT_BIN", DEFAULT_GODOT))
    parser.add_argument("--screenshot", type=Path, help="Capture the native viewer, then exit")
    parser.add_argument("--step", type=int, default=0, help="Initial decision to inspect")
    parser.add_argument("--check", action="store_true", help="Bounded headless playback verification")
    parser.add_argument("--list", action="store_true", help="List recorded episodes and exit")
    parser.add_argument("--export-only", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    run = resolve_run(args.run)
    entries = json.loads((run / "index.json").read_text(encoding="utf-8"))
    if args.list:
        for entry in entries:
            print(f"{entry['id']} | {entry['seconds']:.2f}s | {entry['kills']} kills | "
                  f"reward {entry['reward']:.2f} | {entry['status']}")
        return
    if not entries:
        parser.error("No saved episodes yet. Finish a rollout before opening the viewer.")
    identifier = args.episode or entries[-1]["id"]
    if identifier not in {entry["id"] for entry in entries}:
        parser.error("Episode does not exist in this archive")
    torch.set_num_threads(1)
    if args.export_only:
        ReplayStore(run).export_episode(identifier, args.export_only)
        return
    with tempfile.NamedTemporaryFile(suffix="-zombie-replay.json", delete=False) as stream:
        export = Path(stream.name)
    try:
        print("Preparing matching neural activations for Godot...", flush=True)
        ReplayStore(run).export_episode(identifier, export)
        command = [args.godot, "--path", str(PROJECT), "res://training/replay.tscn"]
        if args.check:
            command.append("--headless")
        command.extend(["--", f"--replay-file={export}", f"--step={args.step}",
                        f"--python-bin={sys.executable}", f"--archive-path={run}"])
        if args.check:
            command.append("--replay-check")
        if args.screenshot:
            command.append(f"--screenshot={args.screenshot.resolve()}")
        subprocess.run(command, check=True)
    finally:
        export.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
