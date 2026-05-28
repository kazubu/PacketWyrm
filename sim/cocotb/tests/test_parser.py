"""cocotb tests for pw_parser_beh.

Drives Scapy-built frames into the behavioural parser and asserts on
the registered output fields. The behavioural RTL mirrors the
parsing spec of rtl/phase3/pw_parser.sv — this is a contract test for
the parsing semantics, not a co-simulation against the production RTL.
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles
from cocotb.clock import Clock

from _pktwyrm_helpers import (
    PW_TEST_MAGIC,
    build_arp_frame,
    build_ipv6_udp_frame,
    build_qinq_frame,
    build_tcp_frame,
    build_test_frame,
    pack_bytes_to_flat,
)


async def reset(dut):
    dut.rst_n.value = 0
    dut.din_valid.value = 0
    dut.din_flat.value = 0
    dut.din_len.value = 0
    dut.din_port.value = 0
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def inject(dut, frame: bytes, port: int = 0):
    dut.din_flat.value = pack_bytes_to_flat(frame)
    dut.din_len.value = len(frame)
    dut.din_port.value = port
    dut.din_valid.value = 1
    await RisingEdge(dut.clk)
    dut.din_valid.value = 0
    # one extra cycle for the registered outputs to settle
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_ipv4_udp_with_test_hdr(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)

    frame = build_test_frame(flow_id=42, sequence=7, tx_ts=0x1122_3344_5566_7788)
    await inject(dut, frame, port=1)

    assert dut.key_valid.value == 1, "key_valid should pulse"
    assert dut.is_ipv4.value == 1
    assert dut.is_udp.value == 1
    assert dut.is_test.value == 1, "test header magic must match"
    assert int(dut.l3_proto.value) == 17
    assert int(dut.l4_dst.value) == 50001
    assert int(dut.l4_src.value) == 49152
    assert int(dut.test_magic.value) == PW_TEST_MAGIC
    assert int(dut.test_flow_id.value) == 42
    assert int(dut.test_sequence.value) == 7
    assert int(dut.test_tx_ts.value) == 0x1122_3344_5566_7788
    assert int(dut.ingress_port.value) == 1
    assert dut.vlan_valid.value == 0


@cocotb.test()
async def test_arp_classification(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    await inject(dut, build_arp_frame())

    assert dut.key_valid.value == 1
    assert dut.is_arp.value == 1
    assert dut.is_ipv4.value == 0
    assert dut.is_udp.value == 0
    assert int(dut.ethertype.value) == 0x0806


@cocotb.test()
async def test_ipv6_udp(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    await inject(dut, build_ipv6_udp_frame(dst_port=1234))

    assert dut.key_valid.value == 1
    assert dut.is_ipv6.value == 1
    assert dut.is_udp.value == 1
    assert dut.is_ipv4.value == 0
    assert int(dut.l3_proto.value) == 17
    assert int(dut.l4_dst.value) == 1234


@cocotb.test()
async def test_ipv4_tcp(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    await inject(dut, build_tcp_frame(dst_port=80))

    assert dut.key_valid.value == 1
    assert dut.is_ipv4.value == 1
    assert dut.is_tcp.value == 1
    assert dut.is_udp.value == 0
    assert int(dut.l3_proto.value) == 6
    assert int(dut.l4_dst.value) == 80


@cocotb.test()
async def test_qinq_vlan(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    await inject(dut, build_qinq_frame())

    assert dut.key_valid.value == 1
    assert dut.is_ipv4.value == 1
    assert dut.vlan_valid.value == 1
    # outer S-VLAN of 200 is what the beh parser exposes
    assert int(dut.vlan_id.value) == 200


@cocotb.test()
async def test_runt_frame_rejected(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    # 8 bytes is shorter than even an Ethernet header
    dut.din_flat.value = 0xDEAD_BEEF
    dut.din_len.value = 8
    dut.din_port.value = 0
    dut.din_valid.value = 1
    await RisingEdge(dut.clk)
    dut.din_valid.value = 0
    await RisingEdge(dut.clk)
    assert dut.key_valid.value == 0
