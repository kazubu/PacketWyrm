"""LabSpec -> tinet YAML + per-router FRR config files.

This is the only place that knows the tinet YAML schema. It emits
exactly the keys tinet (slankdev/tinet) consumes:

  nodes[]            -- containers
    name, image, mounts, interfaces (empty: TAP is moved in postinit)
  switches[]         -- (unused in v1; LIF<->TAP is point-to-point)
  node_configs[]     -- per-node post-create cmds (addr add, link up)
  preinit_cmds[]     -- (unused)
  postinit_cmds[]    -- after `tinet up`: move TAP into each netns

The choice to move the TAP netdev into the container netns (rather
than building a veth bridge) keeps the data path one hop shorter and
matches the existing configs/examples/container-frr/start-r1.sh
recipe.
"""
from __future__ import annotations

import pathlib
from dataclasses import dataclass
from typing import Any

import yaml

from .frr import frr_conf, frr_daemons
from .schema import LabSpec, Router


@dataclass
class GeneratedArtifacts:
    tinet_yaml_path: pathlib.Path
    tinet_yaml_text: str
    frr_dirs: dict[str, pathlib.Path]   # router name -> dir holding frr.conf/daemons


# tinet expects shell commands wrapped as `{cmd: "..."}`. Centralise it so
# the emitter stays readable.
def _cmd(s: str) -> dict[str, str]:
    return {"cmd": s}


def _emit_node(r: Router, frr_dir: pathlib.Path) -> dict[str, Any]:
    """One entry under tinet `nodes:`.

    `interfaces: []` because the TAP is moved into the netns by
    `postinit_cmds`, not by tinet itself. Mount paths are emitted as
    given; callers are responsible for passing an absolute `out_dir`
    if docker requires it.
    """
    return {
        "name": r.name,
        "image": r.image,
        "interfaces": [],
        "mounts": [
            f"{frr_dir}/frr.conf:/etc/frr/frr.conf:ro",
            f"{frr_dir}/daemons:/etc/frr/daemons:ro",
        ],
        "sysctls": [
            {"sysctl": "net.ipv4.ip_forward=1"},
            {"sysctl": "net.ipv6.conf.all.forwarding=1"},
        ],
    }


def _emit_postinit(routers: list[Router]) -> list[dict[str, str]]:
    """Run as root once containers exist: move each TAP into its netns."""
    cmds: list[dict[str, str]] = []
    for r in routers:
        cmds.append(_cmd(
            f"ip link show {r.tap_name} >/dev/null 2>&1 ||"
            f' {{ echo "TAP {r.tap_name} not present; is packetwyrmd up?" >&2; exit 1; }}'
        ))
        cmds.append(_cmd(f"ip link set {r.tap_name} netns {r.name}"))
    return cmds


def _emit_node_config(r: Router) -> dict[str, Any]:
    """Run inside the container netns via `docker exec` (tinet conf)."""
    cmds: list[dict[str, str]] = [
        _cmd("ip link set lo up"),
        _cmd(f"ip link set {r.tap_name} up"),
        _cmd(f"ip addr add {r.addr} dev {r.tap_name}"),
    ]
    if r.mtu is not None:
        cmds.insert(2, _cmd(f"ip link set {r.tap_name} mtu {r.mtu}"))
    if r.addr6 is not None:
        cmds.append(_cmd(f"ip -6 addr add {r.addr6} dev {r.tap_name}"))
    cmds.append(_cmd("/usr/lib/frr/frrinit.sh start"))
    return {"name": r.name, "cmds": cmds}


def _build_spec(lab: LabSpec, frr_root: pathlib.Path) -> tuple[dict[str, Any], dict[str, pathlib.Path]]:
    nodes: list[dict[str, Any]] = []
    node_configs: list[dict[str, Any]] = []
    frr_dirs: dict[str, pathlib.Path] = {}

    for r in lab.routers:
        rdir = frr_root / f"frr-{r.name}"
        frr_dirs[r.name] = rdir
        nodes.append(_emit_node(r, rdir))
        node_configs.append(_emit_node_config(r))

    spec: dict[str, Any] = {
        "nodes": nodes,
        "switches": [],
        "node_configs": node_configs,
        "postinit_cmds": _emit_postinit(lab.routers),
    }
    return spec, frr_dirs


def _dump_yaml(obj: Any) -> str:
    return yaml.safe_dump(obj, default_flow_style=False, sort_keys=False)


def generate(
    lab: LabSpec,
    out_dir: str | pathlib.Path,
    write_files: bool = True,
) -> GeneratedArtifacts:
    """Render `lab` into a tinet spec + per-router FRR configs.

    If write_files is True, materialises everything under out_dir.
    Always returns the rendered tinet YAML text and the (would-be)
    FRR config directories so callers can diff against goldens.
    """
    out = pathlib.Path(out_dir)
    spec, frr_dirs = _build_spec(lab, out)
    tinet_yaml = _dump_yaml(spec)
    tinet_path = out / "tinet.yaml"

    if write_files:
        out.mkdir(parents=True, exist_ok=True)
        tinet_path.write_text(tinet_yaml)
        for r in lab.routers:
            rdir = frr_dirs[r.name]
            rdir.mkdir(parents=True, exist_ok=True)
            (rdir / "frr.conf").write_text(frr_conf(r))
            (rdir / "daemons").write_text(frr_daemons(r))

    return GeneratedArtifacts(
        tinet_yaml_path=tinet_path,
        tinet_yaml_text=tinet_yaml,
        frr_dirs=frr_dirs,
    )
