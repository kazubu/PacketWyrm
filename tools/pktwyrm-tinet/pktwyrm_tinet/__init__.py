"""pktwyrm-tinet: PacketWyrm lab spec -> tinet topology generator.

A lab spec extends a PacketWyrm config with a `routers:` section that
binds containers to PacketWyrm TAPs. The generator emits a tinet
(slankdev/tinet) YAML plus FRR per-router configs that can be brought
up with `tinet up | sudo sh` and `tinet conf | sudo sh`.

Public surface:

  from pktwyrm_tinet import load_lab, generate
  lab = load_lab("lab.yaml")
  artifacts = generate(lab, out_dir="out/")
"""
from .schema import LabSpec, Router, BgpConfig, BgpNeighbor, load_lab, LabError
from .emitter import generate, GeneratedArtifacts

__all__ = [
    "LabSpec",
    "Router",
    "BgpConfig",
    "BgpNeighbor",
    "LabError",
    "load_lab",
    "generate",
    "GeneratedArtifacts",
]
