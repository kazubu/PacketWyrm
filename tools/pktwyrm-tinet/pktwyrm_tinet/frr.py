"""FRR config + /etc/frr/daemons emission for a single router.

The generator writes one directory per router containing:

    <router>/
      frr.conf       -- vtysh-style config (bgpd, etc)
      daemons        -- which FRR daemons to enable

Both are bind-mounted into the FRR container at /etc/frr/.
"""
from __future__ import annotations

from .schema import Router


def frr_conf(router: Router) -> str:
    """Render the vtysh-style frr.conf for `router`."""
    lines: list[str] = []
    lines.append(f"!")
    lines.append(f"hostname {router.name}")
    lines.append(f"log stdout")
    lines.append(f"!")

    if router.bgp is not None:
        bgp = router.bgp
        lines.append(f"router bgp {bgp.asn}")
        lines.append(f" bgp router-id {bgp.router_id}")
        # Disable connected-check / require explicit ebgp-multihop? No:
        # default behaviour is fine for directly-connected eBGP.
        for nb in bgp.neighbors:
            lines.append(f" neighbor {nb.peer} remote-as {nb.remote_as}")
        if bgp.networks:
            lines.append(" address-family ipv4 unicast")
            for net in bgp.networks:
                lines.append(f"  network {net}")
            lines.append(" exit-address-family")
        lines.append("exit")
        lines.append("!")

    lines.append("line vty")
    lines.append("!")
    # Trailing newline keeps `diff` and editors happy.
    return "\n".join(lines) + "\n"


def frr_daemons(router: Router) -> str:
    """Render /etc/frr/daemons listing only the daemons we configured."""
    enabled: dict[str, str] = {
        "zebra": "yes",
        "bgpd": "yes" if router.bgp is not None else "no",
        "ospfd": "no",
        "ospf6d": "no",
        "ripd": "no",
        "ripngd": "no",
        "isisd": "no",
        "pimd": "no",
        "ldpd": "no",
        "nhrpd": "no",
        "eigrpd": "no",
        "babeld": "no",
        "sharpd": "no",
        "pbrd": "no",
        "bfdd": "no",
        "fabricd": "no",
        "vrrpd": "no",
        "pathd": "no",
        "staticd": "yes",
    }
    lines = [f"{name}={state}" for name, state in enabled.items()]
    # FRR's options blocks (read by frrinit.sh). Keep them empty so the
    # daemons run with defaults and bind to the netns interfaces.
    lines += [
        "",
        'vtysh_enable=yes',
        'zebra_options="  -A 127.0.0.1 -s 90000000"',
        'bgpd_options="   -A 127.0.0.1"',
        'staticd_options="-A 127.0.0.1"',
        "",
    ]
    return "\n".join(lines) + "\n"
