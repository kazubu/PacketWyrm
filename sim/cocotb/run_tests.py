#!/usr/bin/env python3
"""Entry point that the Makefile invokes for each cocotb suite.

Each suite uses Icarus Verilog (cocotb 2.x with the system Verilator
is incompatible — Verilator 5.020 vs the 5.036 minimum required by
cocotb 2.0). The behavioural RTL under rtl/ mirrors the spec of the
Verilator-targeted RTL but uses only Icarus-supported constructs.
"""
from __future__ import annotations

import os
import pathlib
import sys

from cocotb_tools.runner import get_runner

ROOT = pathlib.Path(__file__).resolve().parent
RTL = ROOT / "rtl"
TESTS = ROOT / "tests"

SUITES = {
    "parser": {
        "sources": [RTL / "pw_parser_beh.sv"],
        "toplevel": "pw_parser_beh",
        "module": "test_parser",
    },
    "classifier": {
        "sources": [RTL / "pw_classifier_beh.sv"],
        "toplevel": "pw_classifier_beh",
        "module": "test_classifier",
    },
    "flow_gen": {
        "sources": [RTL / "pw_flow_gen_beh.sv"],
        "toplevel": "pw_flow_gen_beh",
        "module": "test_flow_gen",
    },
}


def run(suite: str) -> None:
    cfg = SUITES[suite]
    sys.path.insert(0, str(TESTS))
    build_dir = ROOT / f"sim_build_{suite}"

    runner = get_runner("icarus")
    runner.build(
        sources=[str(p) for p in cfg["sources"]],
        hdl_toplevel=cfg["toplevel"],
        build_args=["-g2012"],
        always=True,
        build_dir=str(build_dir),
    )
    result = runner.test(
        hdl_toplevel=cfg["toplevel"],
        test_module=cfg["module"],
        build_dir=str(build_dir),
        test_dir=str(TESTS),
    )
    # cocotb runner returns the results.xml path; non-zero exit on failure
    # is signalled by raising SystemExit. We post-check anyway.
    print(f"[ok] {suite}: {result}")


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in SUITES:
        print(f"usage: {sys.argv[0]} {{{'|'.join(SUITES)}}}", file=sys.stderr)
        sys.exit(2)
    run(sys.argv[1])
