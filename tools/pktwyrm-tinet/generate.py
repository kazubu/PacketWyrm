#!/usr/bin/env python3
"""Tiny entry-point shim so the tool runs without installation.

Use:

    python3 tools/pktwyrm-tinet/generate.py generate lab.yaml -o out/
"""
from __future__ import annotations

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from pktwyrm_tinet.cli import main

if __name__ == "__main__":
    sys.exit(main())
