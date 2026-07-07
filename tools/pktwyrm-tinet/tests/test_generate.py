"""Golden tests for the lab-spec -> tinet/FRR generator.

These run in pure Python with PyYAML — no docker, no tinet binary,
no FPGA. They lock down the rendered YAML and FRR config so any
behavioural change has to update the goldens.
"""
from __future__ import annotations

import pathlib
import sys
import unittest

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
GOLDEN = HERE / "golden"
sys.path.insert(0, str(ROOT))

from pktwyrm_tinet import load_lab, generate, LabError
from pktwyrm_tinet.frr import frr_conf, frr_daemons


class TwoRouterBgpGolden(unittest.TestCase):
    """Render the two-router BGP fixture and diff against goldens."""

    @classmethod
    def setUpClass(cls):
        cls.lab = load_lab(GOLDEN / "two-router-bgp.lab.yaml")
        # Fixed out_dir keeps mount paths stable across hosts.
        cls.arts = generate(cls.lab, out_dir="/tmp/PW_OUT", write_files=False)

    def test_tinet_yaml_matches_golden(self):
        expected = (GOLDEN / "two-router-bgp.tinet.yaml").read_text()
        self.assertEqual(self.arts.tinet_yaml_text, expected)

    def test_r1_frr_conf_matches_golden(self):
        r1 = next(r for r in self.lab.routers if r.name == "r1")
        expected = (GOLDEN / "two-router-bgp.r1.frr.conf").read_text()
        self.assertEqual(frr_conf(r1), expected)

    def test_r2_frr_conf_matches_golden(self):
        r2 = next(r for r in self.lab.routers if r.name == "r2")
        expected = (GOLDEN / "two-router-bgp.r2.frr.conf").read_text()
        self.assertEqual(frr_conf(r2), expected)

    def test_daemons_matches_golden_for_bgp_router(self):
        r1 = next(r for r in self.lab.routers if r.name == "r1")
        expected = (GOLDEN / "two-router-bgp.daemons").read_text()
        self.assertEqual(frr_daemons(r1), expected)

    def test_tap_names_resolved_from_packetwyrm_config(self):
        names = {r.name: r.tap_name for r in self.lab.routers}
        self.assertEqual(
            names,
            {"r1": "tap-pw-p0-v100", "r2": "tap-pw-p1-v100"},
        )

    def test_mtu_propagated_from_lif(self):
        # LIF 1000/1001 both declare mtu 9000 in the fixture.
        for r in self.lab.routers:
            self.assertEqual(r.mtu, 9000)


class ShellQuotingSafety(unittest.TestCase):
    """The emitted cmds run as root (`tinet ... | sh`); YAML-derived values
    must be shell-quoted so a crafted name/addr can't inject commands."""

    def _router(self, **kw):
        from pktwyrm_tinet.schema import Router
        base = dict(name="r1", image="img", logical_if_id=1000,
                    addr="10.0.0.1/30", tap_name="net0")
        base.update(kw)
        return Router(**base)

    def test_malicious_addr_is_quoted(self):
        from pktwyrm_tinet.emitter import _emit_node_config
        r = self._router(addr="1.2.3.4/30; rm -rf /")
        cmds = [c["cmd"] for c in _emit_node_config(r)["cmds"]]
        joined = "\n".join(cmds)
        # The emitted form is `ip addr add <addr> dev <tap>` (addr BEFORE
        # dev), so an unquoted injection would read `add 1.2.3.4/30; rm ...`.
        # shlex.quote must break that shape by wrapping the whole value.
        self.assertNotIn("ip addr add 1.2.3.4/30; rm -rf /", joined)
        self.assertIn("'1.2.3.4/30; rm -rf /'", joined)

    def test_malicious_tap_and_router_name_quoted(self):
        from pktwyrm_tinet.emitter import _emit_postinit
        r = self._router(tap_name="net0; reboot", name="r1$(id)")
        cmds = [c["cmd"] for c in _emit_postinit([r])]
        joined = "\n".join(cmds)
        self.assertIn("'net0; reboot'", joined)
        self.assertIn("'r1$(id)'", joined)
        self.assertNotIn("netns r1$(id)", joined)   # not left raw


class WriteFilesEndToEnd(unittest.TestCase):
    """Verify the on-disk layout when write_files=True."""

    def test_files_written(self):
        import tempfile
        lab = load_lab(GOLDEN / "two-router-bgp.lab.yaml")
        with tempfile.TemporaryDirectory() as td:
            arts = generate(lab, out_dir=td, write_files=True)
            self.assertTrue(arts.tinet_yaml_path.is_file())
            for r in lab.routers:
                d = arts.frr_dirs[r.name]
                self.assertTrue((d / "frr.conf").is_file(), r.name)
                self.assertTrue((d / "daemons").is_file(), r.name)


class SchemaValidation(unittest.TestCase):
    """Negative tests for the schema loader."""

    def _write_lab(self, tmp, lab_yaml: str, pw_name: str = "two-router-bgp.packetwyrm.yaml"):
        import shutil
        # Copy the PW fixture next to the lab so the relative ref resolves.
        shutil.copy(GOLDEN / pw_name, pathlib.Path(tmp) / pw_name)
        lab_path = pathlib.Path(tmp) / "lab.yaml"
        lab_path.write_text(lab_yaml)
        return lab_path

    def test_missing_packetwyrm_config_rejected(self):
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            (pathlib.Path(td) / "lab.yaml").write_text("routers: []\n")
            with self.assertRaises(LabError):
                load_lab(pathlib.Path(td) / "lab.yaml")

    def test_empty_routers_rejected(self):
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            lab_path = self._write_lab(
                td,
                "packetwyrm_config: ./two-router-bgp.packetwyrm.yaml\nrouters: []\n",
            )
            with self.assertRaises(LabError):
                load_lab(lab_path)

    def test_frr_injection_values_rejected(self):
        """Router name / router-id / neighbor / network go into FRR config +
        shell; a value with a newline or non-IP must be rejected at load."""
        import tempfile
        bad_labs = [
            # router name with an embedded FRR directive / newline
            'routers:\n  - { name: "r1\\n log file /etc/x", image: x,'
            ' logical_if_id: 1000, addr: 192.0.2.1/30 }\n',
            # bad router-id (not an IP)
            'routers:\n  - { name: r1, image: x, logical_if_id: 1000,'
            ' addr: 192.0.2.1/30, routing: { bgp: { asn: 65001,'
            ' router_id: "not-an-ip", neighbors: [] } } }\n',
            # bad network (not a CIDR)
            'routers:\n  - { name: r1, image: x, logical_if_id: 1000,'
            ' addr: 192.0.2.1/30, routing: { bgp: { asn: 65001,'
            ' router_id: 192.0.2.1, neighbors: [], networks: ["oops"] } } }\n',
        ]
        for bad in bad_labs:
            with tempfile.TemporaryDirectory() as td:
                lab_path = self._write_lab(
                    td, "packetwyrm_config: ./two-router-bgp.packetwyrm.yaml\n" + bad)
                with self.assertRaises(LabError):
                    load_lab(lab_path)

    def test_unknown_logical_if_id_rejected(self):
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            lab = """
packetwyrm_config: ./two-router-bgp.packetwyrm.yaml
routers:
  - name: r1
    image: x
    logical_if_id: 9999
    addr: 192.0.2.1/30
"""
            lab_path = self._write_lab(td, lab)
            with self.assertRaises(LabError) as cm:
                load_lab(lab_path)
            self.assertIn("9999", str(cm.exception))

    def test_duplicate_router_name_rejected(self):
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            lab = """
packetwyrm_config: ./two-router-bgp.packetwyrm.yaml
routers:
  - { name: r1, image: x, logical_if_id: 1000, addr: 192.0.2.1/30 }
  - { name: r1, image: x, logical_if_id: 1001, addr: 192.0.2.2/30 }
"""
            lab_path = self._write_lab(td, lab)
            with self.assertRaises(LabError):
                load_lab(lab_path)

    def test_duplicate_logical_if_rejected(self):
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            lab = """
packetwyrm_config: ./two-router-bgp.packetwyrm.yaml
routers:
  - { name: r1, image: x, logical_if_id: 1000, addr: 192.0.2.1/30 }
  - { name: r2, image: x, logical_if_id: 1000, addr: 192.0.2.2/30 }
"""
            lab_path = self._write_lab(td, lab)
            with self.assertRaises(LabError):
                load_lab(lab_path)

    def test_duplicate_addr_rejected(self):
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            lab = """
packetwyrm_config: ./two-router-bgp.packetwyrm.yaml
routers:
  - { name: r1, image: x, logical_if_id: 1000, addr: 192.0.2.1/30 }
  - { name: r2, image: x, logical_if_id: 1001, addr: 192.0.2.1/30 }
"""
            lab_path = self._write_lab(td, lab)
            with self.assertRaises(LabError) as cm:
                load_lab(lab_path)
            self.assertIn("duplicate address", str(cm.exception))

    def test_duplicate_addr6_rejected(self):
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            lab = """
packetwyrm_config: ./two-router-bgp.packetwyrm.yaml
routers:
  - { name: r1, image: x, logical_if_id: 1000, addr: 192.0.2.1/30,
      addr6: "2001:db8::1/64" }
  - { name: r2, image: x, logical_if_id: 1001, addr: 192.0.2.2/30,
      addr6: "2001:db8:0::1/64" }
"""
            lab_path = self._write_lab(td, lab)
            with self.assertRaises(LabError) as cm:
                load_lab(lab_path)
            self.assertIn("duplicate address", str(cm.exception))

    def test_bad_addr_rejected(self):
        """addr goes verbatim into `ip addr add`; it must be a real IPv4
        interface address WITH a prefix, of the v4 family."""
        import tempfile
        bad_addrs = [
            "not-an-ip/24",          # garbage
            "192.0.2.1",             # missing prefix
            "2001:db8::1/64",        # wrong family for addr
            "1.2.3.4/30; rm -rf /",  # shell injection shape
        ]
        for bad in bad_addrs:
            with tempfile.TemporaryDirectory() as td:
                lab = (
                    "packetwyrm_config: ./two-router-bgp.packetwyrm.yaml\n"
                    "routers:\n"
                    f'  - {{ name: r1, image: x, logical_if_id: 1000, addr: "{bad}" }}\n'
                )
                lab_path = self._write_lab(td, lab)
                with self.assertRaises(LabError, msg=bad):
                    load_lab(lab_path)

    def test_bad_addr6_rejected(self):
        import tempfile
        bad_addr6s = [
            "192.0.2.1/30",     # wrong family for addr6
            "2001:db8::1",      # missing prefix
            "hello::/x",        # garbage
        ]
        for bad in bad_addr6s:
            with tempfile.TemporaryDirectory() as td:
                lab = (
                    "packetwyrm_config: ./two-router-bgp.packetwyrm.yaml\n"
                    "routers:\n"
                    "  - { name: r1, image: x, logical_if_id: 1000,\n"
                    f'      addr: 192.0.2.1/30, addr6: "{bad}" }}\n'
                )
                lab_path = self._write_lab(td, lab)
                with self.assertRaises(LabError, msg=bad):
                    load_lab(lab_path)

    def test_non_numeric_scalars_raise_laberror(self):
        """Bad numeric YAML values must surface as LabError (the cli.py
        handler), not a raw ValueError/TypeError traceback."""
        import tempfile
        bad_labs = [
            # non-numeric asn
            'routers:\n  - { name: r1, image: x, logical_if_id: 1000,'
            ' addr: 192.0.2.1/30, routing: { bgp: { asn: "sixty-five",'
            ' router_id: 192.0.2.1 } } }\n',
            # non-numeric remote_as
            'routers:\n  - { name: r1, image: x, logical_if_id: 1000,'
            ' addr: 192.0.2.1/30, routing: { bgp: { asn: 65001,'
            ' router_id: 192.0.2.1,'
            ' neighbors: [ { peer: 192.0.2.2, remote_as: "xx" } ] } } }\n',
            # remote_as out of range
            'routers:\n  - { name: r1, image: x, logical_if_id: 1000,'
            ' addr: 192.0.2.1/30, routing: { bgp: { asn: 65001,'
            ' router_id: 192.0.2.1,'
            ' neighbors: [ { peer: 192.0.2.2, remote_as: 0 } ] } } }\n',
            # non-numeric logical_if_id
            'routers:\n  - { name: r1, image: x, logical_if_id: "one",'
            ' addr: 192.0.2.1/30 }\n',
            # routing.bgp is not a mapping
            'routers:\n  - { name: r1, image: x, logical_if_id: 1000,'
            ' addr: 192.0.2.1/30, routing: { bgp: [ 65001 ] } }\n',
            # router entry is not a mapping
            'routers:\n  - 42\n',
        ]
        for bad in bad_labs:
            with tempfile.TemporaryDirectory() as td:
                lab_path = self._write_lab(
                    td, "packetwyrm_config: ./two-router-bgp.packetwyrm.yaml\n" + bad)
                with self.assertRaises(LabError, msg=bad):
                    load_lab(lab_path)


class FrrEmission(unittest.TestCase):
    """Sanity checks that don't need a fixture."""

    def test_no_bgp_router_disables_bgpd(self):
        from pktwyrm_tinet.schema import Router
        r = Router(
            name="rx", image="x", logical_if_id=0, addr="10/8",
            tap_name="tap-x", global_port=0, vlan=0,
        )
        self.assertIn("bgpd=no", frr_daemons(r))
        # frr.conf should not contain a router bgp block
        conf = frr_conf(r)
        self.assertNotIn("router bgp", conf)

    def _bgp_router(self, neighbors=(), networks=()):
        from pktwyrm_tinet.schema import BgpConfig, BgpNeighbor, Router
        bgp = BgpConfig(
            asn=65001, router_id="192.0.2.1",
            neighbors=[BgpNeighbor(peer=p, remote_as=a) for p, a in neighbors],
            networks=list(networks),
        )
        return Router(
            name="rx", image="x", logical_if_id=0, addr="10.0.0.1/30",
            bgp=bgp, tap_name="tap-x", global_port=0, vlan=0,
        )

    def test_v6_networks_under_ipv6_unicast(self):
        """IPv6 networks must land in `address-family ipv6 unicast` (bgpd
        rejects them under ipv4 unicast, silently never advertising)."""
        r = self._bgp_router(
            neighbors=[("192.0.2.2", 65002)],
            networks=["10.0.1.0/24", "2001:db8:1::/48"],
        )
        conf = frr_conf(r)
        lines = conf.splitlines()
        v4_at = lines.index(" address-family ipv4 unicast")
        v4_end = lines.index(" exit-address-family", v4_at)
        v6_at = lines.index(" address-family ipv6 unicast")
        v6_end = lines.index(" exit-address-family", v6_at)
        self.assertIn("  network 10.0.1.0/24", lines[v4_at:v4_end])
        self.assertNotIn("  network 2001:db8:1::/48", lines[v4_at:v4_end])
        self.assertIn("  network 2001:db8:1::/48", lines[v6_at:v6_end])

    def test_v6_neighbor_activated_under_ipv6_unicast(self):
        """An IPv6 peer needs `neighbor X activate` under ipv6 unicast (FRR
        only auto-activates under ipv4 unicast)."""
        r = self._bgp_router(neighbors=[("2001:db8::2", 65002)])
        conf = frr_conf(r)
        self.assertIn(" neighbor 2001:db8::2 remote-as 65002\n", conf)
        self.assertIn(" address-family ipv6 unicast\n", conf)
        self.assertIn("  neighbor 2001:db8::2 activate\n", conf)

    def test_v4_only_config_has_no_ipv6_block(self):
        r = self._bgp_router(
            neighbors=[("192.0.2.2", 65002)], networks=["10.0.1.0/24"],
        )
        conf = frr_conf(r)
        self.assertNotIn("address-family ipv6 unicast", conf)
        # v4 neighbors are auto-activated; no stray activate lines.
        self.assertNotIn("activate", conf)


if __name__ == "__main__":
    unittest.main()
