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


if __name__ == "__main__":
    unittest.main()
