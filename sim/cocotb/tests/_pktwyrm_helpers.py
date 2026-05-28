"""Helpers shared by the cocotb test modules.

The Scapy frames are constructed using familiar protocol stacks
(`Ether()/IP()/UDP()/payload`) and then packed into the 1024-bit flat
input vector the behavioural RTL accepts.
"""
from __future__ import annotations

import struct
from dataclasses import dataclass

from scapy.all import Ether, IP, UDP, TCP, Dot1Q, Dot1AD, ARP, IPv6, ICMPv6EchoRequest

PW_TEST_MAGIC = 0xA502_7E57


def pack_bytes_to_flat(data: bytes, width_bits: int = 1024) -> int:
    """Pack a byte string so byte N lands at bits [8N+7:8N] of the result."""
    width_bytes = width_bits // 8
    if len(data) > width_bytes:
        raise ValueError(f"frame {len(data)}B exceeds {width_bytes}B bus")
    val = 0
    for i, b in enumerate(data):
        val |= b << (8 * i)
    return val


def build_test_frame(
    src_ip: str = "192.0.2.1",
    dst_ip: str = "192.0.2.2",
    src_port: int = 49152,
    dst_port: int = 50001,
    flow_id: int = 42,
    sequence: int = 0,
    tx_ts: int = 0,
    magic: int = PW_TEST_MAGIC,
    vlan: int | None = None,
    extra_pad: int = 4,
) -> bytes:
    """A UDP packet carrying a PacketWyrm test header in its payload."""
    test_hdr = struct.pack(
        ">IIIQQ",
        magic,
        0x0001_0000,
        flow_id,
        sequence,
        tx_ts,
    )
    payload = test_hdr + bytes(extra_pad)
    eth = Ether(src="02:a5:02:00:00:01", dst="02:a5:02:00:00:02")
    if vlan is not None:
        eth = eth / Dot1Q(vlan=vlan)
    pkt = eth / IP(src=src_ip, dst=dst_ip) / UDP(sport=src_port, dport=dst_port) / payload
    return bytes(pkt)


def build_arp_frame() -> bytes:
    pkt = Ether(src="02:a5:02:00:00:01", dst="ff:ff:ff:ff:ff:ff") / ARP(
        psrc="192.0.2.1", pdst="192.0.2.2"
    )
    return bytes(pkt)


def build_ipv6_udp_frame(dst_port: int = 50001) -> bytes:
    pkt = (
        Ether(src="02:a5:02:00:00:01", dst="02:a5:02:00:00:02")
        / IPv6(src="2001:db8::1", dst="2001:db8::2")
        / UDP(sport=49152, dport=dst_port)
        / (b"\x00" * 16)
    )
    return bytes(pkt)


def build_tcp_frame(dst_port: int = 80) -> bytes:
    pkt = (
        Ether(src="02:a5:02:00:00:01", dst="02:a5:02:00:00:02")
        / IP(src="192.0.2.1", dst="192.0.2.2")
        / TCP(sport=49152, dport=dst_port)
        / (b"\x00" * 16)
    )
    return bytes(pkt)


def build_qinq_frame() -> bytes:
    pkt = (
        Ether(src="02:a5:02:00:00:01", dst="02:a5:02:00:00:02", type=0x88A8)
        / Dot1Q(vlan=200, type=0x8100)
        / Dot1Q(vlan=300)
        / IP(src="192.0.2.1", dst="192.0.2.2")
        / UDP(sport=49152, dport=50001)
        / (b"\x00" * 8)
    )
    return bytes(pkt)


@dataclass
class ClassifierEntry:
    """Mirrors the 96-bit entry layout in pw_classifier_beh.sv."""

    enable: bool = False
    action: int = 0
    priority: int = 0xFF
    flow_id: int = 0
    l4_dst: int = 0
    l3_proto: int = 0
    mask_l4_dst: bool = False
    mask_l3_proto: bool = False
    mask_is_test: bool = False
    mask_flow_id: bool = False

    def pack(self) -> int:
        v = 0
        v |= (1 if self.enable else 0) << 95
        v |= (self.action & 0x7) << 92
        v |= (self.priority & 0xFF) << 84
        v |= (self.flow_id & 0xFFFFFFFF) << 52
        v |= (self.l4_dst & 0xFFFF) << 36
        v |= (self.l3_proto & 0xFF) << 28
        v |= (1 if self.mask_l4_dst else 0) << 27
        v |= (1 if self.mask_l3_proto else 0) << 26
        v |= (1 if self.mask_is_test else 0) << 25
        v |= (1 if self.mask_flow_id else 0) << 24
        return v
