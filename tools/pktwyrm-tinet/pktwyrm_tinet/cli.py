"""`pktwyrm-tinet` CLI.

Sub-commands:

  generate LAB.YAML -o OUT/         emit tinet.yaml + per-router FRR configs
  up       LAB.YAML [-o OUT/]       generate + start daemon + tinet up + conf
  conf     [-o OUT/]                re-apply tinet conf
  down     [-o OUT/]                tinet down + stop daemon
  status   [-o OUT/]                show lab state
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys

from .schema import load_lab, LabError
from .emitter import generate
from . import lab as lab_mod


def _add_out_dir(p: argparse.ArgumentParser, default: str = "out") -> None:
    p.add_argument(
        "-o", "--out-dir", default=default,
        help=f"output / state directory (default: ./{default})",
    )


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        prog="pktwyrm-tinet",
        description="Generate and orchestrate PacketWyrm + tinet labs.",
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    g = sub.add_parser("generate", help="emit tinet.yaml + FRR configs")
    g.add_argument("lab", help="path to lab.yaml")
    _add_out_dir(g)
    g.add_argument("--dry-run", action="store_true",
                   help="print tinet YAML to stdout without writing files")

    up = sub.add_parser("up", help="generate + start daemon + tinet up/conf")
    up.add_argument("lab", help="path to lab.yaml")
    _add_out_dir(up)
    up.add_argument("--daemon-bin", default=None,
                    help="path to packetwyrmd (default: from PATH)")

    cf = sub.add_parser("conf", help="re-apply tinet conf to a running lab")
    _add_out_dir(cf)

    dn = sub.add_parser("down", help="tinet down + stop packetwyrmd")
    _add_out_dir(dn)
    dn.add_argument("--keep-daemon", action="store_true",
                    help="tear down containers but leave packetwyrmd running")

    st = sub.add_parser("status", help="print JSON state of the lab")
    _add_out_dir(st)

    args = p.parse_args(argv)
    out_dir = pathlib.Path(args.out_dir).resolve()

    try:
        if args.cmd == "generate":
            lab = load_lab(args.lab)
            arts = generate(lab, out_dir=out_dir, write_files=not args.dry_run)
            if args.dry_run:
                sys.stdout.write(arts.tinet_yaml_text)
            else:
                print(f"wrote {arts.tinet_yaml_path}")
                for name, d in arts.frr_dirs.items():
                    print(f"wrote {d}/frr.conf, {d}/daemons  ({name})")
            return 0

        if args.cmd == "up":
            state = lab_mod.cmd_up(
                pathlib.Path(args.lab), out_dir, daemon_bin=args.daemon_bin,
            )
            print(f"lab up: packetwyrmd pid {state.packetwyrmd_pid},"
                  f" {len(state.tap_names)} TAP(s) attached")
            return 0

        if args.cmd == "conf":
            lab_mod.cmd_conf(out_dir)
            print("conf applied")
            return 0

        if args.cmd == "down":
            lab_mod.cmd_down(out_dir, keep_daemon=args.keep_daemon)
            print("lab down")
            return 0

        if args.cmd == "status":
            print(json.dumps(lab_mod.cmd_status(out_dir), indent=2))
            return 0

    except LabError as e:
        print(f"lab-spec error: {e}", file=sys.stderr)
        return 2
    except lab_mod.LabRuntimeError as e:
        print(f"lab runtime error: {e}", file=sys.stderr)
        return 3

    return 1


if __name__ == "__main__":
    sys.exit(main())
