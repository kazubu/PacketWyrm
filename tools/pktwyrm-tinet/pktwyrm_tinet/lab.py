"""Lab lifecycle orchestration: up / down / conf / status.

Wraps the three steps an operator would otherwise run by hand:

    1. packetwyrmd -c packetwyrm.yaml &     # create TAPs
    2. tinet up    -c tinet.yaml | sh       # create containers + move TAPs
    3. tinet conf  -c tinet.yaml | sh       # configure FRR in each ctr

State (the packetwyrmd PID, the tinet.yaml path, the TAP list) is
persisted under `<out_dir>/.pktwyrm-lab.json` so `down` and `status`
work without re-parsing the lab spec.

This module is the only one in pktwyrm_tinet that does I/O against
processes and the filesystem; the generator (`emitter.py`) stays
pure.
"""
from __future__ import annotations

import dataclasses
import errno
import json
import os
import pathlib
import shlex
import shutil
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Sequence

from .schema import LabSpec, load_lab, LabError
from .emitter import generate

STATE_FILE = ".pktwyrm-lab.json"


class LabRuntimeError(Exception):
    """Raised when the lab cannot reach the requested state."""


@dataclass
class LabState:
    packetwyrmd_pid: int
    packetwyrm_config: str
    tinet_yaml: str
    tap_names: list[str]
    started_at: float

    def to_json(self) -> str:
        return json.dumps(dataclasses.asdict(self), indent=2, sort_keys=True)

    @classmethod
    def from_json(cls, s: str) -> "LabState":
        d = json.loads(s)
        return cls(**d)


# ----- pure helpers ---------------------------------------------------------

def state_path(out_dir: pathlib.Path) -> pathlib.Path:
    return out_dir / STATE_FILE


def read_state(out_dir: pathlib.Path) -> LabState | None:
    p = state_path(out_dir)
    if not p.is_file():
        return None
    try:
        return LabState.from_json(p.read_text())
    except (json.JSONDecodeError, TypeError, KeyError) as e:
        raise LabRuntimeError(f"state file {p} corrupted: {e}")


def write_state(state: LabState, out_dir: pathlib.Path) -> None:
    state_path(out_dir).write_text(state.to_json())


def delete_state(out_dir: pathlib.Path) -> None:
    p = state_path(out_dir)
    if p.exists():
        p.unlink()


def pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except OSError as e:
        return e.errno == errno.EPERM   # exists but not ours
    return True


def tinet_up_cmd(tinet_yaml: pathlib.Path) -> str:
    return f"tinet up -c {shlex.quote(str(tinet_yaml))} | sh"


def tinet_conf_cmd(tinet_yaml: pathlib.Path) -> str:
    return f"tinet conf -c {shlex.quote(str(tinet_yaml))} | sh"


def tinet_down_cmd(tinet_yaml: pathlib.Path) -> str:
    return f"tinet down -c {shlex.quote(str(tinet_yaml))} | sh"


# ----- side-effects ---------------------------------------------------------

def _require_root() -> None:
    if os.geteuid() != 0:
        raise LabRuntimeError(
            "pktwyrm-lab needs root (packetwyrmd + ip link set + docker)"
        )


def _require_binary(name: str) -> str:
    path = shutil.which(name)
    if not path:
        raise LabRuntimeError(f"required binary {name!r} not on PATH")
    return path


def _run_shell(cmd: str, *, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, shell=True, check=check)


def _wait_for_taps(tap_names: Sequence[str], *, timeout_s: float = 10.0) -> None:
    """Poll `ip link show <tap>` until all TAPs appear or timeout."""
    deadline = time.monotonic() + timeout_s
    missing = list(tap_names)
    while missing and time.monotonic() < deadline:
        still_missing = []
        for t in missing:
            rc = subprocess.run(
                ["ip", "link", "show", t],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            ).returncode
            if rc != 0:
                still_missing.append(t)
        missing = still_missing
        if missing:
            time.sleep(0.2)
    if missing:
        raise LabRuntimeError(
            f"timed out waiting {timeout_s}s for TAPs: {', '.join(missing)}."
            f" Is packetwyrmd actually creating them?"
        )


def _start_daemon(daemon_bin: str, packetwyrm_config: pathlib.Path, log_path: pathlib.Path) -> int:
    """Fork packetwyrmd into the background; return its PID."""
    # `with` so the PARENT's copy of the log fd is closed on both the success
    # and the error path (the child keeps its own inherited dup) -- otherwise
    # each _start_daemon leaks an fd into a long-lived caller.
    with open(log_path, "ab", buffering=0) as log_fd:
        proc = subprocess.Popen(
            [daemon_bin, "-c", str(packetwyrm_config), "-v"],
            stdout=log_fd, stderr=log_fd, stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
        # Give it a fraction of a second to fail fast on bad config.
        time.sleep(0.3)
        if proc.poll() is not None and proc.returncode != 0:
            raise LabRuntimeError(
                f"packetwyrmd exited rc={proc.returncode} at startup;"
                f" see {log_path}"
            )
        return proc.pid


def _stop_daemon(pid: int, *, timeout_s: float = 5.0) -> None:
    """SIGTERM then SIGKILL the daemon; quiet if it's already gone."""
    if not pid_alive(pid):
        return
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        return
    deadline = time.monotonic() + timeout_s
    while pid_alive(pid) and time.monotonic() < deadline:
        time.sleep(0.1)
    if pid_alive(pid):
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass


# ----- top-level commands ---------------------------------------------------

def cmd_up(lab_path: pathlib.Path, out_dir: pathlib.Path, *, daemon_bin: str | None = None) -> LabState:
    """Generate artifacts, start packetwyrmd, then tinet up + conf."""
    _require_root()

    existing = read_state(out_dir) if out_dir.exists() else None
    if existing is not None and pid_alive(existing.packetwyrmd_pid):
        raise LabRuntimeError(
            f"lab already up (packetwyrmd pid {existing.packetwyrmd_pid});"
            f" run `down` first"
        )

    lab = load_lab(lab_path)
    out_dir = out_dir.resolve()
    arts = generate(lab, out_dir=out_dir, write_files=True)

    daemon_bin = daemon_bin or _require_binary("packetwyrmd")
    _require_binary("tinet")
    _require_binary("ip")

    pid = _start_daemon(daemon_bin, lab.packetwyrm_config_path, out_dir / "packetwyrmd.log")
    tap_names = [r.tap_name for r in lab.routers]
    tinet_up_done = False
    try:
        _wait_for_taps(tap_names)
        _run_shell(tinet_up_cmd(arts.tinet_yaml_path))
        tinet_up_done = True
        _run_shell(tinet_conf_cmd(arts.tinet_yaml_path))
    except Exception:
        # No state file is written on this path, so a later `down` can't clean
        # up. If `tinet up` already created containers/netns (e.g. `conf`
        # failed), best-effort tear them down here so they don't leak.
        if tinet_up_done:
            _run_shell(tinet_down_cmd(arts.tinet_yaml_path), check=False)
        _stop_daemon(pid)
        raise

    state = LabState(
        packetwyrmd_pid=pid,
        packetwyrm_config=str(lab.packetwyrm_config_path),
        tinet_yaml=str(arts.tinet_yaml_path),
        tap_names=tap_names,
        started_at=time.time(),
    )
    write_state(state, out_dir)
    return state


def cmd_down(out_dir: pathlib.Path, *, keep_daemon: bool = False) -> None:
    """`tinet down` first (so containers release the TAP netdev), then daemon."""
    _require_root()
    state = read_state(out_dir)
    if state is None:
        # Nothing to do — but still try tinet down if a tinet.yaml is there,
        # so an orphaned container set can be cleaned up.
        tinet_yaml = out_dir / "tinet.yaml"
        if tinet_yaml.is_file():
            _run_shell(tinet_down_cmd(tinet_yaml), check=False)
        return

    _run_shell(tinet_down_cmd(pathlib.Path(state.tinet_yaml)), check=False)
    if not keep_daemon:
        _stop_daemon(state.packetwyrmd_pid)
    delete_state(out_dir)


def cmd_conf(out_dir: pathlib.Path) -> None:
    """Re-run `tinet conf` against an already-up lab."""
    _require_root()
    state = read_state(out_dir)
    if state is None:
        raise LabRuntimeError(f"no state at {out_dir}; bring the lab up first")
    if not pid_alive(state.packetwyrmd_pid):
        raise LabRuntimeError(
            f"packetwyrmd pid {state.packetwyrmd_pid} is gone; run `down` then `up`"
        )
    _run_shell(tinet_conf_cmd(pathlib.Path(state.tinet_yaml)))


def cmd_status(out_dir: pathlib.Path) -> dict:
    """Read-only summary; doesn't need root."""
    state = read_state(out_dir)
    if state is None:
        return {"state": "down", "out_dir": str(out_dir)}
    return {
        "state": "up" if pid_alive(state.packetwyrmd_pid) else "stale",
        "packetwyrmd_pid": state.packetwyrmd_pid,
        "packetwyrmd_alive": pid_alive(state.packetwyrmd_pid),
        "packetwyrm_config": state.packetwyrm_config,
        "tinet_yaml": state.tinet_yaml,
        "tap_names": state.tap_names,
        "started_at": state.started_at,
    }
