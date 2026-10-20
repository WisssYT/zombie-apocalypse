"""One Godot process as a Gymnasium environment, on Windows or Linux.

Uses the Godot RL Agents wire protocol. This adapter supplies correct Gymnasium
termination/truncation and lets SB3 manage auto-reset and terminal observations.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import socket
import subprocess

import gymnasium as gym
import numpy as np
from godot_rl.core.godot_env import GodotEnv

PROJECT = Path(__file__).resolve().parents[1]
OBSERVATION_SIZE = 586
DEFAULT_GODOT = (
    r"C:\Users\user\Downloads\Godot_v4.6.2-stable_win64.exe"
    r"\Godot_v4.6.2-stable_win64_console.exe"
)


class ProjectProcess(GodotEnv):
    def __init__(self, godot, project, *, seed, port, episode_seconds, show_window, log_path):
        self.project = Path(project).resolve()
        self.game_log = Path(log_path)
        self.game_log.parent.mkdir(parents=True, exist_ok=True)
        self._log = self.game_log.open("w", encoding="utf-8")
        self._closed = False
        try:
            super().__init__(
                env_path=str(godot), seed=seed, port=port,
                show_window=show_window, convert_action_space=True,
                episode_seconds=episode_seconds,
            )
        except BaseException:
            self.close()
            raise

    def _set_platform_suffix(self, path):
        return path  # Godot editor/runtime binaries need not end in .x86_64.

    def check_platform(self, filename):
        if not Path(filename).is_file():
            raise FileNotFoundError(f"Godot executable not found: {filename}")

    def _launch_env(self, env_path, port, show_window, framerate, seed,
                    action_repeat, speedup, **kwargs):
        cmd = [env_path, "--path", str(self.project), "res://training.tscn",
               f"--port={port}", f"--env_seed={seed}", "--action_repeat=4",
               "--speedup=1", f"--episode_seconds={kwargs['episode_seconds']}"]
        if not show_window:
            cmd.extend(["--headless", "--disable-render-loop", "--fixed-fps", "60"])
        self.proc = subprocess.Popen(
            cmd, stdout=self._log, stderr=subprocess.STDOUT,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
        )

    def _start_server(self):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
            server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            server.bind(("127.0.0.1", self.port))
            server.listen(1)
            server.settimeout(20)
            try:
                connection, _ = server.accept()
            except socket.timeout as exc:
                raise RuntimeError(f"Godot did not connect. See {self.game_log}") from exc
        connection.settimeout(20)
        return connection

    def _get_json_dict(self):
        # Upstream's read loop doesn't detect EOF; fail clearly instead of hanging.
        def read_exact(count):
            data = bytearray()
            while len(data) < count:
                chunk = self.connection.recv(count - len(data))
                if not chunk:
                    raise ConnectionError(f"Godot disconnected. See {self.game_log}")
                data.extend(chunk)
            return data
        size = int.from_bytes(read_exact(4), "little")
        if not 0 < size < 16 * 1024 * 1024:
            raise ConnectionError(f"Invalid Godot message size: {size}")
        return json.loads(read_exact(size).decode("utf-8"))

    def reset(self, seed=None):
        # Upstream drops reset info; replay needs the genuine initial world state.
        self._send_as_json({"type": "reset"})
        response = self._get_json_dict()
        if response.get("type") != "reset":
            raise RuntimeError("Expected a Godot reset reply")
        return self._process_obs(response["obs"]), response.get("info", [{}])

    def close(self):
        if self._closed:
            return
        self._closed = True
        connection = getattr(self, "connection", None)
        if connection is not None:
            try:
                self._send_as_json({"type": "close"})
            except (OSError, ConnectionError):
                pass
            connection.close()
        proc = getattr(self, "proc", None)
        if proc is not None:
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
        self._log.close()
        import atexit
        atexit.unregister(self._close)

    def _close(self):
        self.close()


class ZombieEnv(gym.Env):
    metadata = {"render_modes": ["human"], "render_fps": 60}

    def __init__(self, godot=None, project=PROJECT, *, seed=1, port=11008,
                 episode_seconds=60, show_window=False, log_path=None):
        super().__init__()
        self.godot = str(godot or os.environ.get("GODOT_BIN", DEFAULT_GODOT))
        self.project = Path(project)
        self.seed_value = seed
        self.port = port
        self.episode_seconds = episode_seconds
        self.show_window = show_window
        self.render_mode = "human" if show_window else None
        self.log_path = log_path or PROJECT / "training/runs" / f"godot-{port}.log"
        self.observation_space = gym.spaces.Box(-1, 1, (OBSERVATION_SIZE,), np.float32)
        self.action_space = gym.spaces.Box(-1, 1, (7,), np.float32)
        self.client = None
        self.replay_enabled = False
        self._needs_reset = True
        self._connect()

    def _connect(self):
        self.client = ProjectProcess(
            self.godot, self.project, seed=self.seed_value, port=self.port,
            episode_seconds=self.episode_seconds, show_window=self.show_window,
            log_path=self.log_path,
        )
        if self.client.num_envs != 1 or self.client.action_space.shape != (7,):
            self.close()
            raise RuntimeError("Expected one agent with seven continuous controls")
        if self.replay_enabled:
            self.client.call("enable_replay")

    def enable_replay(self):
        self.replay_enabled = True
        self.client.call("enable_replay")

    def _observation(self, raw):
        obs = np.asarray(raw[0]["obs"], dtype=np.float32)
        if not self.observation_space.contains(obs):
            raise ValueError("Godot observation must be 586 finite floats in [-1,1]")
        return obs

    def reset(self, *, seed=None, options=None):
        super().reset(seed=seed)
        if seed is not None:
            if seed != self.seed_value:
                self.close()
                self.seed_value = seed
                self._connect()
            self.client.call("reset_sequence")
        raw, infos = self.client.reset()
        self._needs_reset = False
        return self._observation(raw), dict(infos[0], seed=self.seed_value)

    def step(self, action):
        if self._needs_reset:
            raise RuntimeError("Call reset() before stepping a new/finished round")
        action = np.asarray(action, dtype=np.float32)
        if not self.action_space.contains(action):
            raise ValueError("Action must be seven finite floats in [-1,1]")
        raw, rewards, dones, _, infos = self.client.step(action[None, :])
        info = infos[0]
        terminated = bool(info["terminated"])
        truncated = bool(info["truncated"])
        if bool(dones[0]) != (terminated or truncated):
            raise RuntimeError("Godot terminal status disagrees with its info")
        self._needs_reset = terminated or truncated
        return self._observation(raw), float(rewards[0]), terminated, truncated, info

    def close(self):
        if self.client is not None:
            self.client.close()
            self.client = None
