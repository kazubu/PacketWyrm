"""Lab-spec data model + YAML loader.

A *lab spec* is a small YAML file the operator hand-writes:

    packetwyrm_config: ./packetwyrm.yaml   # path, relative to this file
    routers:
      - name: r1
        image: quay.io/frrouting/frr:latest
        logical_if_id: 1000
        addr: "192.0.2.1/30"
        addr6: "2001:db8::1/64"            # optional
        routing:
          bgp:
            asn: 65001
            router_id: "192.0.2.1"
            neighbors:
              - { peer: "192.0.2.2", remote_as: 65002 }

The PacketWyrm config it points at is loaded read-only so the
generator can resolve `logical_if_id` to the kernel TAP name
(`tap-pw-p<gport>-v<vlan>`).
"""
from __future__ import annotations

import os
import pathlib
from dataclasses import dataclass, field
from typing import Any

import yaml


class LabError(Exception):
    """Raised on any schema or cross-reference failure."""


@dataclass
class BgpNeighbor:
    peer: str
    remote_as: int


@dataclass
class BgpConfig:
    asn: int
    router_id: str
    neighbors: list[BgpNeighbor] = field(default_factory=list)
    networks: list[str] = field(default_factory=list)


@dataclass
class Router:
    name: str
    image: str
    logical_if_id: int
    addr: str
    addr6: str | None = None
    bgp: BgpConfig | None = None

    # Resolved at load time from the referenced PacketWyrm config.
    tap_name: str = ""
    global_port: int = -1
    vlan: int = 0
    mtu: int | None = None


@dataclass
class LabSpec:
    packetwyrm_config_path: pathlib.Path
    packetwyrm_config: dict[str, Any]
    routers: list[Router]


def _require(d: dict, key: str, where: str) -> Any:
    if key not in d:
        raise LabError(f"{where}: missing required key '{key}'")
    return d[key]


def _parse_bgp(raw: dict, where: str) -> BgpConfig:
    asn = int(_require(raw, "asn", where))
    if not (1 <= asn <= 4294967295):
        raise LabError(f"{where}: asn {asn} out of range")
    router_id = str(_require(raw, "router_id", where))
    neighbors_raw = raw.get("neighbors", [])
    if not isinstance(neighbors_raw, list):
        raise LabError(f"{where}: neighbors must be a list")
    neighbors = []
    for i, nb in enumerate(neighbors_raw):
        loc = f"{where}.neighbors[{i}]"
        peer = str(_require(nb, "peer", loc))
        remote_as = int(_require(nb, "remote_as", loc))
        neighbors.append(BgpNeighbor(peer=peer, remote_as=remote_as))
    networks = [str(x) for x in raw.get("networks", [])]
    return BgpConfig(
        asn=asn, router_id=router_id, neighbors=neighbors, networks=networks
    )


def _parse_router(raw: dict, idx: int) -> Router:
    where = f"routers[{idx}]"
    name = str(_require(raw, "name", where))
    image = str(_require(raw, "image", where))
    lif = int(_require(raw, "logical_if_id", where))
    addr = str(_require(raw, "addr", where))
    addr6 = raw.get("addr6")
    addr6 = str(addr6) if addr6 is not None else None

    bgp = None
    routing = raw.get("routing")
    if routing is not None:
        if not isinstance(routing, dict):
            raise LabError(f"{where}.routing must be a mapping")
        if "bgp" in routing:
            bgp = _parse_bgp(routing["bgp"], f"{where}.routing.bgp")

    return Router(
        name=name,
        image=image,
        logical_if_id=lif,
        addr=addr,
        addr6=addr6,
        bgp=bgp,
    )


def _resolve_tap_names(routers: list[Router], pw_cfg: dict, where: str) -> None:
    """Fill router.tap_name/global_port/vlan from the PacketWyrm config."""
    lifs = pw_cfg.get("logical_interfaces", [])
    if not isinstance(lifs, list):
        raise LabError(f"{where}: logical_interfaces must be a list")

    # Index logical_interfaces by id.
    by_id: dict[int, dict] = {}
    for lif in lifs:
        if not isinstance(lif, dict) or "id" not in lif:
            continue
        by_id[int(lif["id"])] = lif

    for r in routers:
        if r.logical_if_id not in by_id:
            raise LabError(
                f"router {r.name!r}: logical_if_id {r.logical_if_id} not"
                f" found in PacketWyrm config"
            )
        lif = by_id[r.logical_if_id]
        gport = int(lif.get("global_port", -1))
        vlan = int(lif.get("vlan", 0))
        if gport < 0:
            raise LabError(
                f"router {r.name!r}: logical_if_id {r.logical_if_id} has"
                f" no global_port"
            )
        r.global_port = gport
        r.vlan = vlan
        r.tap_name = f"tap-pw-p{gport}-v{vlan}"
        mtu = lif.get("mtu")
        if mtu is not None:
            r.mtu = int(mtu)


def _check_unique(routers: list[Router]) -> None:
    seen_names: set[str] = set()
    seen_lifs: set[int] = set()
    for r in routers:
        if r.name in seen_names:
            raise LabError(f"duplicate router name {r.name!r}")
        if r.logical_if_id in seen_lifs:
            raise LabError(
                f"logical_if_id {r.logical_if_id} attached to >1 router"
                f" (last: {r.name!r})"
            )
        seen_names.add(r.name)
        seen_lifs.add(r.logical_if_id)


def load_lab(path: str | os.PathLike) -> LabSpec:
    lab_path = pathlib.Path(path).resolve()
    with open(lab_path) as f:
        raw = yaml.safe_load(f) or {}

    if not isinstance(raw, dict):
        raise LabError(f"{lab_path}: top-level must be a mapping")

    pw_rel = _require(raw, "packetwyrm_config", str(lab_path))
    pw_path = (lab_path.parent / str(pw_rel)).resolve()
    if not pw_path.is_file():
        raise LabError(f"packetwyrm_config not found: {pw_path}")
    with open(pw_path) as f:
        pw_cfg = yaml.safe_load(f) or {}

    routers_raw = raw.get("routers", [])
    if not isinstance(routers_raw, list) or not routers_raw:
        raise LabError("routers: at least one router is required")
    routers = [_parse_router(r, i) for i, r in enumerate(routers_raw)]

    _check_unique(routers)
    _resolve_tap_names(routers, pw_cfg, str(lab_path))

    return LabSpec(
        packetwyrm_config_path=pw_path,
        packetwyrm_config=pw_cfg,
        routers=routers,
    )
