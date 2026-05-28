"""cocotb tests for pw_flow_gen_beh.

Drives the token-bucket rate control inputs and observes the emitted
frames. Uses Scapy to decode the frame bytes the RTL produced and
asserts on the Ethernet/IPv4/UDP/test-header fields.
"""
import struct

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge
from cocotb.clock import Clock
from scapy.all import Ether, IP, UDP

from _pktwyrm_helpers import PW_TEST_MAGIC


FRAME_LEN_PAYLOAD = 32  # default param in the beh module


def flat_to_bytes(val: int, nbytes: int) -> bytes:
    return bytes((val >> (8 * i)) & 0xFF for i in range(nbytes))


async def reset(dut):
    dut.rst_n.value = 0
    dut.enable.value = 0
    dut.tokens_fp.value = 0
    dut.burst_bytes.value = 0
    dut.egress_port.value = 0
    dut.src_mac.value = 0x02_a5_02_00_00_01
    dut.dst_mac.value = 0x02_a5_02_00_00_02
    dut.vlan_en.value = 0
    dut.vlan_id.value = 0
    dut.src_ip.value = 0xC000_0201
    dut.dst_ip.value = 0xC000_0202
    dut.udp_sport.value = 49152
    dut.udp_dport.value = 50001
    dut.timestamp.value = 0
    await ClockCycles(dut.clk, 4)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def capture_first_frame(dut, max_cycles: int = 200):
    """Wait until frame_valid pulses, then return (bytes, length)."""
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        if dut.frame_valid.value == 1:
            nbytes = int(dut.frame_len.value)
            data = flat_to_bytes(int(dut.frame_flat.value), nbytes)
            return data, nbytes
    raise TimeoutError("no frame emitted")


@cocotb.test()
async def test_disabled_emits_nothing(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    dut.enable.value = 0
    dut.tokens_fp.value = 0x10_0000  # plenty
    dut.burst_bytes.value = 4096
    # Watch for any emission over many cycles.
    for _ in range(50):
        await RisingEdge(dut.clk)
        assert dut.frame_valid.value == 0


@cocotb.test()
async def test_emits_well_formed_frame(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    dut.enable.value = 1
    # Q16.16: 16 bytes/cycle -> 16<<16 = 0x10_0000 tokens / cycle
    dut.tokens_fp.value = 0x10_0000
    dut.burst_bytes.value = 4096

    data, nbytes = await capture_first_frame(dut)
    expected_len = 14 + 20 + 8 + FRAME_LEN_PAYLOAD
    assert nbytes == expected_len, f"len={nbytes} != {expected_len}"

    pkt = Ether(data)
    assert pkt.haslayer(IP), "missing IP layer"
    assert pkt.haslayer(UDP), "missing UDP layer"
    assert pkt[IP].src == "192.0.2.1"
    assert pkt[IP].dst == "192.0.2.2"
    assert pkt[UDP].sport == 49152
    assert pkt[UDP].dport == 50001

    # Verify the PacketWyrm test header at UDP payload offset 0
    udp_payload = bytes(pkt[UDP].payload)
    assert len(udp_payload) >= 32
    magic = struct.unpack(">I", udp_payload[0:4])[0]
    assert magic == PW_TEST_MAGIC, f"magic 0x{magic:08x} != PW_TEST_MAGIC"


@cocotb.test()
async def test_sequence_increments(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    dut.enable.value = 1
    dut.tokens_fp.value = 0x10_0000
    dut.burst_bytes.value = 4096

    seqs = []
    for _ in range(3):
        data, _ = await capture_first_frame(dut)
        pkt = Ether(data)
        udp_payload = bytes(pkt[UDP].payload)
        seq = struct.unpack(">Q", udp_payload[12:20])[0]
        seqs.append(seq)
    assert seqs == [0, 1, 2], f"sequence not monotonic: {seqs}"


@cocotb.test()
async def test_token_bucket_throttles(dut):
    """Tiny token rate must cause many idle cycles between emissions."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    dut.enable.value = 1
    # 0.5 byte / cycle Q16.16 -> 0x8000
    dut.tokens_fp.value = 0x8000
    # Burst cap is 1 frame's worth so the bucket can't pre-charge.
    dut.burst_bytes.value = 74

    # Wait for first emission, then verify there are idle cycles before
    # the next one (vs. back-to-back at high rate).
    await capture_first_frame(dut)

    idle = 0
    for _ in range(300):
        await RisingEdge(dut.clk)
        if dut.frame_valid.value == 1:
            break
        idle += 1
    assert idle > 50, f"expected >50 idle cycles, got {idle}"


@cocotb.test()
async def test_vlan_extends_frame(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    dut.enable.value = 1
    dut.tokens_fp.value = 0x10_0000
    dut.burst_bytes.value = 4096
    dut.vlan_en.value = 1
    dut.vlan_id.value = 0xABC

    data, nbytes = await capture_first_frame(dut)
    expected_len = 14 + 4 + 20 + 8 + FRAME_LEN_PAYLOAD
    assert nbytes == expected_len, f"vlan frame len {nbytes} != {expected_len}"
    # Bytes 12-13 should be the 0x8100 VLAN ethertype
    assert data[12] == 0x81 and data[13] == 0x00, "missing VLAN tag"
    # Bytes 14-15 carry the VID with high 4 bits in byte 14
    vid = ((data[14] & 0x0F) << 8) | data[15]
    assert vid == 0xABC, f"vid 0x{vid:03x} != 0xabc"
