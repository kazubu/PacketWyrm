"""`pktwyrm-tinet generate` CLI."""
from __future__ import annotations

import argparse
import sys

from .schema import load_lab, LabError
from .emitter import generate


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        prog="pktwyrm-tinet",
        description="Generate a tinet topology from a PacketWyrm lab spec.",
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    g = sub.add_parser("generate", help="emit tinet.yaml + per-router FRR configs")
    g.add_argument("lab", help="path to lab.yaml")
    g.add_argument(
        "-o", "--out-dir", default="out",
        help="output directory (default: ./out)",
    )
    g.add_argument(
        "--dry-run", action="store_true",
        help="print tinet YAML to stdout without writing files",
    )

    args = p.parse_args(argv)

    try:
        lab = load_lab(args.lab)
    except LabError as e:
        print(f"lab-spec error: {e}", file=sys.stderr)
        return 2

    # Docker bind mounts need absolute paths; resolve here so callers
    # (and goldens) see the same string the user would.
    import pathlib as _pl
    out_dir = _pl.Path(args.out_dir).resolve()
    arts = generate(lab, out_dir=out_dir, write_files=not args.dry_run)
    if args.dry_run:
        sys.stdout.write(arts.tinet_yaml_text)
    else:
        print(f"wrote {arts.tinet_yaml_path}")
        for name, d in arts.frr_dirs.items():
            print(f"wrote {d}/frr.conf, {d}/daemons  ({name})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
