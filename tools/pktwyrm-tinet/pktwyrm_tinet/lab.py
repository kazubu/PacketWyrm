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
import stat
import subprocess
import sys
import tempfile
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
    # /proc/<pid>/stat starttime (clock ticks) captured at launch. Together with
    # the PID it identifies THIS daemon instance, so a stale state file whose PID
    # was recycled to an unrelated process is not mistaken for the daemon (and
    # never SIGKILL'd). Default 0 = legacy state file (fall back to a cmdline
    # check only).
    packetwyrmd_start_ticks: int = 0

    def to_json(self) -> str:
        return json.dumps(dataclasses.asdict(self), indent=2, sort_keys=True)

    @classmethod
    def from_json(cls, s: str) -> "LabState":
        d = json.loads(s)
        return cls(**d)


# ----- pure helpers ---------------------------------------------------------

def state_path(out_dir: pathlib.Path) -> pathlib.Path:
    return out_dir / STATE_FILE


def require_safe_out_dir(out_dir: pathlib.Path) -> pathlib.Path:
    """Root lifecycle commands (up/down/conf) trust files under out_dir: the
    state file names a tinet YAML whose GENERATED SHELL SCRIPT is piped to `sh`
    as root. So out_dir must not be tamperable by a non-root user, or a local
    attacker could plant a state file / tinet YAML and get root command
    execution (the documented workflow uses /tmp/lab-frr). Require: exists, is a
    real directory (not a symlink), root-owned, and NOT group/world-writable.
    Returns the resolved path."""
    real = out_dir.resolve()
    try:
        st = os.lstat(real)
    except OSError as e:
        raise LabRuntimeError(f"out-dir {out_dir}: {e}")
    if not stat.S_ISDIR(st.st_mode):
        raise LabRuntimeError(f"out-dir {out_dir} is not a directory")
    # Must be owned by whoever runs the lifecycle command (root in production,
    # via _require_root). A dir owned by a DIFFERENT (lower-priv) user is the
    # attack: that user could swap in a hostile state / tinet YAML that root
    # then executes. Keying on geteuid() (not a hardcoded 0) keeps this the
    # right property under root AND lets the non-root test suite exercise it.
    euid = os.geteuid()
    if st.st_uid != euid:
        raise LabRuntimeError(
            f"out-dir {out_dir} must be owned by the invoking user (uid {euid}); "
            f"it is owned by uid {st.st_uid} -- run: install -d -m 0700 {out_dir}")
    if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise LabRuntimeError(
            f"out-dir {out_dir} is group/world-writable (mode "
            f"{oct(st.st_mode & 0o777)}); a local user could inject a root-run "
            f"tinet script -- `sudo chmod 0700 {out_dir}`")
    return real


def ensure_safe_out_dir(out_dir: pathlib.Path) -> pathlib.Path:
    """Create out_dir root-owned 0700 if absent, then validate it is safe."""
    real = out_dir.resolve()
    if not real.exists():
        real.mkdir(parents=True, mode=0o700)
    return require_safe_out_dir(real)


def _within(out_dir: pathlib.Path, candidate: str) -> bool:
    """True iff `candidate` resolves to a path inside out_dir (so a state file
    can't redirect a root-run tinet invocation at an out-of-tree YAML)."""
    try:
        pathlib.Path(candidate).resolve().relative_to(out_dir.resolve())
        return True
    except (ValueError, OSError):
        return False


def read_state(out_dir: pathlib.Path) -> LabState | None:
    p = state_path(out_dir)
    if not p.is_file():
        return None
    try:
        return LabState.from_json(p.read_text())
    except (json.JSONDecodeError, TypeError, KeyError) as e:
        raise LabRuntimeError(f"state file {p} corrupted: {e}")


def write_state(state: LabState, out_dir: pathlib.Path) -> None:
    # Atomic write with a private (0600) mode via a temp file in the same dir +
    # rename, so a concurrent reader never sees a half-written file and the
    # state (which drives root-run commands) isn't left world-readable/writable.
    d = out_dir.resolve()
    fd, tmp = tempfile.mkstemp(prefix=".pktwyrm-lab.", dir=str(d))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(state.to_json())
        os.replace(tmp, str(state_path(d)))
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


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


def _proc_starttime(pid: int) -> int | None:
    """/proc/<pid>/stat field 22 (starttime, clock ticks), or None if gone."""
    try:
        stat = pathlib.Path(f"/proc/{pid}/stat").read_text()
    except OSError:
        return None
    # comm (2nd field) is parenthesized and may contain spaces/parens; parse the
    # numeric fields after the last ')'. starttime is field 22 overall = index 19
    # of the post-comm fields (which start at field 3, "state").
    rp = stat.rfind(")")
    if rp < 0:
        return None
    parts = stat[rp + 2:].split()
    try:
        return int(parts[19])
    except (IndexError, ValueError):
        return None


def _proc_is_packetwyrmd(pid: int) -> bool:
    try:
        cmd = pathlib.Path(f"/proc/{pid}/cmdline").read_bytes()
    except OSError:
        return False
    return b"packetwyrmd" in cmd


def daemon_alive_and_ours(pid: int, start_ticks: int) -> bool:
    """True only if `pid` is still OUR packetwyrmd -- alive, matching the saved
    /proc starttime (so a recycled PID is rejected), and a packetwyrmd cmdline.
    Legacy state (start_ticks == 0): fall back to the cmdline check alone."""
    if pid <= 0:
        return False
    st = _proc_starttime(pid)
    if st is None:
        return False                       # not alive
    if start_ticks and st != start_ticks:
        return False                       # PID reused by another process
    return _proc_is_packetwyrmd(pid)


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
    # Create (0700, root-owned) or validate out_dir BEFORE trusting/reading any
    # state or writing artifacts a root-run tinet will later execute.
    out_dir = ensure_safe_out_dir(out_dir)

    existing = read_state(out_dir) if out_dir.exists() else None
    if existing is not None and daemon_alive_and_ours(
            existing.packetwyrmd_pid, existing.packetwyrmd_start_ticks):
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
    start_ticks = _proc_starttime(pid) or 0
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
        packetwyrmd_start_ticks=start_ticks,
    )
    write_state(state, out_dir)
    return state


def cmd_down(out_dir: pathlib.Path, *, keep_daemon: bool = False) -> None:
    """`tinet down` first (so containers release the TAP netdev), then daemon."""
    _require_root()
    out_dir = require_safe_out_dir(out_dir)
    state = read_state(out_dir)
    if state is None:
        # Nothing to do — but still try tinet down if a tinet.yaml is there,
        # so an orphaned container set can be cleaned up.
        tinet_yaml = out_dir / "tinet.yaml"
        if tinet_yaml.is_file():
            _run_shell(tinet_down_cmd(tinet_yaml), check=False)
        return

    # Refuse a state file that points its tinet YAML outside out_dir (a tampered
    # state must not redirect the root-run `tinet | sh` at an out-of-tree YAML).
    if not _within(out_dir, state.tinet_yaml):
        raise LabRuntimeError(
            f"state tinet_yaml {state.tinet_yaml} is outside out-dir {out_dir}; "
            f"refusing to run it as root")
    _run_shell(tinet_down_cmd(pathlib.Path(state.tinet_yaml)), check=False)
    if not keep_daemon:
        # Only signal the PID if it is still OUR daemon: a stale state whose PID
        # was recycled must NOT get an unrelated (possibly root) process killed.
        if daemon_alive_and_ours(state.packetwyrmd_pid, state.packetwyrmd_start_ticks):
            _stop_daemon(state.packetwyrmd_pid)
        else:
            print(f"note: packetwyrmd pid {state.packetwyrmd_pid} is not our daemon"
                  f" (gone or PID reused); skipping kill, cleaning up state")
    delete_state(out_dir)


def cmd_conf(out_dir: pathlib.Path) -> None:
    """Re-run `tinet conf` against an already-up lab."""
    _require_root()
    out_dir = require_safe_out_dir(out_dir)
    state = read_state(out_dir)
    if state is None:
        raise LabRuntimeError(f"no state at {out_dir}; bring the lab up first")
    if not daemon_alive_and_ours(state.packetwyrmd_pid, state.packetwyrmd_start_ticks):
        raise LabRuntimeError(
            f"packetwyrmd pid {state.packetwyrmd_pid} is gone; run `down` then `up`"
        )
    if not _within(out_dir, state.tinet_yaml):
        raise LabRuntimeError(
            f"state tinet_yaml {state.tinet_yaml} is outside out-dir {out_dir}; "
            f"refusing to run it as root")
    _run_shell(tinet_conf_cmd(pathlib.Path(state.tinet_yaml)))


def cmd_status(out_dir: pathlib.Path) -> dict:
    """Read-only summary; doesn't need root. `packetwyrmd_alive` is a liveness
    HINT (PID present); `packetwyrmd_ours` is the stricter identity check that the
    up/down/conf paths use before acting (so a recycled PID is never killed)."""
    state = read_state(out_dir)
    if state is None:
        return {"state": "down", "out_dir": str(out_dir)}
    return {
        "state": "up" if pid_alive(state.packetwyrmd_pid) else "stale",
        "packetwyrmd_pid": state.packetwyrmd_pid,
        "packetwyrmd_alive": pid_alive(state.packetwyrmd_pid),
        "packetwyrmd_ours": daemon_alive_and_ours(
            state.packetwyrmd_pid, state.packetwyrmd_start_ticks),
        "packetwyrm_config": state.packetwyrm_config,
        "tinet_yaml": state.tinet_yaml,
        "tap_names": state.tap_names,
        "started_at": state.started_at,
    }
