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

import ipaddress
import os
import pathlib
import re
from dataclasses import dataclass, field
from typing import Any

import yaml

# Router name becomes an FRR `hostname` directive and a shell/container name;
# restrict it so a lab YAML value can't inject FRR config lines or shell.
_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")


def _valid_name(where: str, val: str) -> str:
    if not _NAME_RE.match(val):
        raise LabError(f"{where}: invalid name {val!r} (allowed: [A-Za-z0-9_.-], "
                       f"leading alnum)")
    return val


def _valid_ip(where: str, val: str) -> str:
    """An IPv4/IPv6 address (no prefix). Goes into FRR router-id / neighbor."""
    try:
        ipaddress.ip_address(val)
    except ValueError:
        raise LabError(f"{where}: invalid IP address {val!r}")
    return val


def _valid_cidr(where: str, val: str) -> str:
    """An IPv4/IPv6 network in CIDR form. Goes into FRR `network`."""
    try:
        ipaddress.ip_network(val, strict=False)
    except ValueError:
        raise LabError(f"{where}: invalid network/CIDR {val!r}")
    return val


def _valid_ifaddr(where: str, val: str, version: int) -> str:
    """An interface address WITH prefix length (e.g. '192.0.2.1/30').

    Goes verbatim into `ip addr add <val> dev ...` inside the container,
    so require a well-formed address of the expected family. The prefix
    is mandatory: a bare address would silently become /32 (or /128).
    """
    try:
        if "/" not in val:
            raise ValueError
        ifa = ipaddress.ip_interface(val)
        if ifa.version != version:
            raise ValueError
    except ValueError:
        raise LabError(
            f"{where}: invalid IPv{version} address/prefix {val!r}"
        )
    return val


def _to_int(where: str, val: Any) -> int:
    """int() that reports bad YAML values as LabError, not ValueError."""
    if isinstance(val, bool):
        raise LabError(f"{where}: expected an integer, got {val!r}")
    try:
        return int(val)
    except (TypeError, ValueError):
        raise LabError(f"{where}: expected an integer, got {val!r}")


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


def _parse_bgp(raw: Any, where: str) -> BgpConfig:
    if not isinstance(raw, dict):
        raise LabError(f"{where}: must be a mapping")
    asn = _to_int(f"{where}.asn", _require(raw, "asn", where))
    if not (1 <= asn <= 4294967295):
        raise LabError(f"{where}: asn {asn} out of range")
    router_id = _valid_ip(f"{where}.router_id", str(_require(raw, "router_id", where)))
    neighbors_raw = raw.get("neighbors", [])
    if not isinstance(neighbors_raw, list):
        raise LabError(f"{where}: neighbors must be a list")
    neighbors = []
    for i, nb in enumerate(neighbors_raw):
        loc = f"{where}.neighbors[{i}]"
        if not isinstance(nb, dict):
            raise LabError(f"{loc}: must be a mapping")
        peer = _valid_ip(f"{loc}.peer", str(_require(nb, "peer", loc)))
        remote_as = _to_int(f"{loc}.remote_as", _require(nb, "remote_as", loc))
        if not (1 <= remote_as <= 4294967295):
            raise LabError(f"{loc}: remote_as {remote_as} out of range")
        neighbors.append(BgpNeighbor(peer=peer, remote_as=remote_as))
    networks = [_valid_cidr(f"{where}.networks[{i}]", str(x))
                for i, x in enumerate(raw.get("networks", []))]
    return BgpConfig(
        asn=asn, router_id=router_id, neighbors=neighbors, networks=networks
    )


def _parse_router(raw: Any, idx: int) -> Router:
    where = f"routers[{idx}]"
    if not isinstance(raw, dict):
        raise LabError(f"{where}: must be a mapping")
    name = _valid_name(f"{where}.name", str(_require(raw, "name", where)))
    image = str(_require(raw, "image", where))
    lif = _to_int(f"{where}.logical_if_id", _require(raw, "logical_if_id", where))
    addr = _valid_ifaddr(f"{where}.addr", str(_require(raw, "addr", where)), 4)
    addr6 = raw.get("addr6")
    if addr6 is not None:
        addr6 = _valid_ifaddr(f"{where}.addr6", str(addr6), 6)

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
        by_id[_to_int(f"{where}: logical_interfaces id", lif["id"])] = lif

    for r in routers:
        if r.logical_if_id not in by_id:
            raise LabError(
                f"router {r.name!r}: logical_if_id {r.logical_if_id} not"
                f" found in PacketWyrm config"
            )
        lif = by_id[r.logical_if_id]
        loc = f"router {r.name!r}: logical_if {r.logical_if_id}"
        gport = _to_int(f"{loc} global_port", lif.get("global_port", -1))
        vlan = _to_int(f"{loc} vlan", lif.get("vlan", 0))
        if gport < 0:
            raise LabError(
                f"router {r.name!r}: logical_if_id {r.logical_if_id} has"
                f" no global_port"
            )
        r.global_port = gport
        r.vlan = vlan
        # Match packetwyrmd's TAP naming (config.c): an explicit logical_if
        # `name` is used verbatim; only when absent does the daemon synthesize
        # tap-pw-p<gport>-v<vlan>. Mirror that here or we'd wait for the wrong
        # netdev and time out when a custom name is configured.
        lif_name = lif.get("name")
        r.tap_name = lif_name if lif_name else f"tap-pw-p{gport}-v{vlan}"
        mtu = lif.get("mtu")
        if mtu is not None:
            r.mtu = _to_int(f"{loc} mtu", mtu)


def _check_unique(routers: list[Router]) -> None:
    seen_names: set[str] = set()
    seen_lifs: set[int] = set()
    # Compare addresses in normalized (parsed) form so e.g. an IPv6 address
    # written two ways still collides. addr/addr6 were validated in
    # _parse_router, so ip_interface() cannot fail here.
    seen_addrs: set[ipaddress.IPv4Interface | ipaddress.IPv6Interface] = set()
    for r in routers:
        if r.name in seen_names:
            raise LabError(f"duplicate router name {r.name!r}")
        if r.logical_if_id in seen_lifs:
            raise LabError(
                f"logical_if_id {r.logical_if_id} attached to >1 router"
                f" (last: {r.name!r})"
            )
        for a in (r.addr, r.addr6):
            if a is None:
                continue
            ifa = ipaddress.ip_interface(a)
            if ifa in seen_addrs:
                raise LabError(
                    f"duplicate address {a!r} assigned to >1 router"
                    f" (last: {r.name!r})"
                )
            seen_addrs.add(ifa)
        seen_names.add(r.name)
        seen_lifs.add(r.logical_if_id)


def _load_yaml(path: pathlib.Path, what: str) -> Any:
    """Read+parse a YAML file, reporting failures as LabError (so the CLI's
    handler prints a message instead of a raw traceback)."""
    try:
        with open(path) as f:
            return yaml.safe_load(f)
    except OSError as e:
        raise LabError(f"cannot read {what} {path}: {e.strerror or e}")
    except yaml.YAMLError as e:
        raise LabError(f"{path}: invalid YAML: {e}")


def load_lab(path: str | os.PathLike) -> LabSpec:
    lab_path = pathlib.Path(path).resolve()
    raw = _load_yaml(lab_path, "lab spec") or {}

    if not isinstance(raw, dict):
        raise LabError(f"{lab_path}: top-level must be a mapping")

    pw_rel = _require(raw, "packetwyrm_config", str(lab_path))
    pw_path = (lab_path.parent / str(pw_rel)).resolve()
    if not pw_path.is_file():
        raise LabError(f"packetwyrm_config not found: {pw_path}")
    pw_cfg = _load_yaml(pw_path, "packetwyrm_config") or {}

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
