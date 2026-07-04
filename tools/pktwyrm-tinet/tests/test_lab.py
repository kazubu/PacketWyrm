"""Unit tests for the lab orchestrator's testable surface.

The full `up`/`down` flow needs root + docker + tinet, so it lives
outside CI. Here we test:

  - state file round-trip
  - pid_alive
  - shell command construction
  - status output for the down/up/stale cases
  - subprocess invocation via monkeypatch (no real processes spawned)
"""
from __future__ import annotations

import os
import pathlib
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
GOLDEN = HERE / "golden"
sys.path.insert(0, str(ROOT))

from pktwyrm_tinet import lab as lab_mod
from pktwyrm_tinet.lab import (
    LabState,
    LabRuntimeError,
    pid_alive,
    read_state,
    state_path,
    tinet_conf_cmd,
    tinet_down_cmd,
    tinet_up_cmd,
    write_state,
)


def _sample_state(pid: int = 12345) -> LabState:
    return LabState(
        packetwyrmd_pid=pid,
        packetwyrm_config="/etc/packetwyrm/single.yaml",
        tinet_yaml="/tmp/lab/tinet.yaml",
        tap_names=["tap-pw-p0-v100", "tap-pw-p1-v100"],
        started_at=1700000000.0,
    )


class StateRoundTrip(unittest.TestCase):

    def test_to_and_from_json(self):
        s1 = _sample_state()
        s2 = LabState.from_json(s1.to_json())
        self.assertEqual(s1, s2)

    def test_write_read(self):
        with tempfile.TemporaryDirectory() as td:
            d = pathlib.Path(td)
            write_state(_sample_state(), d)
            self.assertTrue(state_path(d).is_file())
            got = read_state(d)
            self.assertEqual(got, _sample_state())

    def test_missing_state_returns_none(self):
        with tempfile.TemporaryDirectory() as td:
            self.assertIsNone(read_state(pathlib.Path(td)))

    def test_corrupted_state_raises(self):
        with tempfile.TemporaryDirectory() as td:
            d = pathlib.Path(td)
            state_path(d).write_text("not json")
            with self.assertRaises(LabRuntimeError):
                read_state(d)


class PidAlive(unittest.TestCase):

    def test_self_pid_is_alive(self):
        self.assertTrue(pid_alive(os.getpid()))

    def test_zero_pid_not_alive(self):
        self.assertFalse(pid_alive(0))

    def test_certainly_dead_pid_not_alive(self):
        # Pick a high pid that almost certainly isn't ours.
        self.assertFalse(pid_alive(2_000_000_000))


class ShellCmdConstruction(unittest.TestCase):

    def test_up_cmd_quotes_path(self):
        p = pathlib.Path("/tmp/with space/tinet.yaml")
        self.assertEqual(
            tinet_up_cmd(p),
            "tinet up -c '/tmp/with space/tinet.yaml' | sh",
        )

    def test_conf_and_down_cmd(self):
        p = pathlib.Path("/x/tinet.yaml")
        self.assertEqual(tinet_conf_cmd(p), "tinet conf -c /x/tinet.yaml | sh")
        self.assertEqual(tinet_down_cmd(p), "tinet down -c /x/tinet.yaml | sh")


class StatusOutput(unittest.TestCase):

    def test_down_when_no_state(self):
        with tempfile.TemporaryDirectory() as td:
            got = lab_mod.cmd_status(pathlib.Path(td))
            self.assertEqual(got["state"], "down")

    def test_up_when_pid_alive(self):
        with tempfile.TemporaryDirectory() as td:
            d = pathlib.Path(td)
            write_state(_sample_state(pid=os.getpid()), d)
            got = lab_mod.cmd_status(d)
            self.assertEqual(got["state"], "up")
            self.assertTrue(got["packetwyrmd_alive"])

    def test_stale_when_pid_gone(self):
        with tempfile.TemporaryDirectory() as td:
            d = pathlib.Path(td)
            write_state(_sample_state(pid=2_000_000_000), d)
            got = lab_mod.cmd_status(d)
            self.assertEqual(got["state"], "stale")
            self.assertFalse(got["packetwyrmd_alive"])


class CmdDownIdempotent(unittest.TestCase):

    def test_no_state_and_no_tinet_yaml_is_no_op(self):
        with mock.patch.object(lab_mod, "_require_root", lambda: None):
            with tempfile.TemporaryDirectory() as td:
                # Should not raise.
                lab_mod.cmd_down(pathlib.Path(td))

    def test_orphan_tinet_yaml_triggers_tinet_down(self):
        """If a tinet.yaml is present but no state file, we still try to
        clean up via tinet down (containers may have leaked)."""
        calls = []

        def fake_run(cmd, *, check=True):
            calls.append((cmd, check))
            return subprocess.CompletedProcess(args=cmd, returncode=0)

        with tempfile.TemporaryDirectory() as td:
            d = pathlib.Path(td)
            (d / "tinet.yaml").write_text("nodes: []\n")
            with mock.patch.object(lab_mod, "_require_root", lambda: None), \
                 mock.patch.object(lab_mod, "_run_shell", fake_run):
                lab_mod.cmd_down(d)
        self.assertEqual(len(calls), 1)
        self.assertIn("tinet down", calls[0][0])
        # Best-effort cleanup must not raise on tinet failure.
        self.assertFalse(calls[0][1])

    def test_state_present_runs_down_then_stops_daemon(self):
        calls = []
        stopped = []

        def fake_run(cmd, *, check=True):
            calls.append(cmd)
            return subprocess.CompletedProcess(args=cmd, returncode=0)

        def fake_stop(pid, *, timeout_s=5.0):
            stopped.append(pid)

        with tempfile.TemporaryDirectory() as td:
            d = pathlib.Path(td)
            write_state(_sample_state(pid=99999999), d)
            (d / "tinet.yaml").write_text("nodes: []\n")
            with mock.patch.object(lab_mod, "_require_root", lambda: None), \
                 mock.patch.object(lab_mod, "daemon_alive_and_ours",
                                   lambda pid, ticks: True), \
                 mock.patch.object(lab_mod, "_run_shell", fake_run), \
                 mock.patch.object(lab_mod, "_stop_daemon", fake_stop):
                lab_mod.cmd_down(d)
            # State file must be removed afterwards.
            self.assertIsNone(read_state(d))
        self.assertEqual(len(calls), 1)
        self.assertIn("tinet down", calls[0])
        self.assertEqual(stopped, [99999999])

    def test_keep_daemon_skips_stop(self):
        stopped = []
        with tempfile.TemporaryDirectory() as td:
            d = pathlib.Path(td)
            write_state(_sample_state(pid=os.getpid()), d)
            (d / "tinet.yaml").write_text("x")
            with mock.patch.object(lab_mod, "_require_root", lambda: None), \
                 mock.patch.object(
                     lab_mod, "_run_shell",
                     lambda cmd, *, check=True: subprocess.CompletedProcess(
                         args=cmd, returncode=0)), \
                 mock.patch.object(
                     lab_mod, "_stop_daemon",
                     lambda pid, *, timeout_s=5.0: stopped.append(pid)):
                lab_mod.cmd_down(d, keep_daemon=True)
        self.assertEqual(stopped, [])

    def test_recycled_pid_not_killed(self):
        """A stale state whose PID was reused must NOT be SIGKILL'd (P1)."""
        stopped = []
        with tempfile.TemporaryDirectory() as td:
            d = pathlib.Path(td)
            write_state(_sample_state(pid=os.getpid()), d)   # a live but wrong PID
            (d / "tinet.yaml").write_text("x")
            with mock.patch.object(lab_mod, "_require_root", lambda: None), \
                 mock.patch.object(lab_mod, "daemon_alive_and_ours",
                                   lambda pid, ticks: False), \
                 mock.patch.object(
                     lab_mod, "_run_shell",
                     lambda cmd, *, check=True: subprocess.CompletedProcess(
                         args=cmd, returncode=0)), \
                 mock.patch.object(
                     lab_mod, "_stop_daemon",
                     lambda pid, *, timeout_s=5.0: stopped.append(pid)):
                lab_mod.cmd_down(d)
            self.assertIsNone(read_state(d))   # state still cleaned up
        self.assertEqual(stopped, [])          # but nothing was killed


class CmdConfRequiresRunningDaemon(unittest.TestCase):

    def test_no_state_raises(self):
        with tempfile.TemporaryDirectory() as td:
            with mock.patch.object(lab_mod, "_require_root", lambda: None):
                with self.assertRaises(LabRuntimeError):
                    lab_mod.cmd_conf(pathlib.Path(td))

    def test_dead_pid_raises(self):
        with tempfile.TemporaryDirectory() as td:
            d = pathlib.Path(td)
            write_state(_sample_state(pid=2_000_000_000), d)
            with mock.patch.object(lab_mod, "_require_root", lambda: None):
                with self.assertRaises(LabRuntimeError):
                    lab_mod.cmd_conf(d)

    def test_runs_tinet_conf_when_daemon_alive(self):
        calls = []
        with tempfile.TemporaryDirectory() as td:
            d = pathlib.Path(td)
            write_state(_sample_state(pid=os.getpid()), d)
            with mock.patch.object(lab_mod, "_require_root", lambda: None), \
                 mock.patch.object(lab_mod, "daemon_alive_and_ours",
                                   lambda pid, ticks: True), \
                 mock.patch.object(
                     lab_mod, "_run_shell",
                     lambda cmd, *, check=True: calls.append(cmd) or
                     subprocess.CompletedProcess(args=cmd, returncode=0)):
                lab_mod.cmd_conf(d)
        self.assertEqual(len(calls), 1)
        self.assertIn("tinet conf", calls[0])


class CmdUpRefusesIfAlreadyUp(unittest.TestCase):

    def test_existing_alive_pid_blocks_up(self):
        with tempfile.TemporaryDirectory() as td:
            d = pathlib.Path(td)
            write_state(_sample_state(pid=os.getpid()), d)
            with mock.patch.object(lab_mod, "_require_root", lambda: None), \
                 mock.patch.object(lab_mod, "daemon_alive_and_ours",
                                   lambda pid, ticks: True):
                with self.assertRaises(LabRuntimeError) as cm:
                    lab_mod.cmd_up(GOLDEN / "two-router-bgp.lab.yaml", d)
                self.assertIn("already up", str(cm.exception))


class WaitForTaps(unittest.TestCase):

    def test_taps_present_returns_immediately(self):
        with mock.patch.object(
            lab_mod.subprocess, "run",
            return_value=subprocess.CompletedProcess(args=[], returncode=0),
        ):
            t0 = time.monotonic()
            lab_mod._wait_for_taps(["tap-pw-p0-v100"], timeout_s=0.5)
            self.assertLess(time.monotonic() - t0, 0.2)

    def test_taps_missing_times_out(self):
        with mock.patch.object(
            lab_mod.subprocess, "run",
            return_value=subprocess.CompletedProcess(args=[], returncode=1),
        ):
            with self.assertRaises(LabRuntimeError):
                lab_mod._wait_for_taps(["tap-x"], timeout_s=0.3)


if __name__ == "__main__":
    unittest.main()
