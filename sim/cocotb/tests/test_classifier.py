"""cocotb tests for pw_classifier_beh.

Drives the 96-bit-encoded classifier table and a parsed key over flat
inputs, then asserts the priority-resolved hit, action, and flow_id.
"""
import cocotb
from cocotb.triggers import Timer

from _pktwyrm_helpers import ClassifierEntry


# Action encoding (matches pw_classifier_pkg::pw_action_e)
ACT_DROP = 0
ACT_TEST_RX = 1
ACT_PUNT = 2
ACT_FORWARD = 4


def load_table(dut, rows):
    for i, e in enumerate(rows):
        dut.entry[i].value = e.pack()


def disable_all(dut):
    for i in range(4):
        dut.entry[i].value = 0


async def settle(dut):
    # Pure combinational module; one Timer tick lets the simulator
    # propagate the new inputs.
    await Timer(1, unit="ns")


@cocotb.test()
async def test_no_match_when_table_empty(dut):
    disable_all(dut)
    dut.key_valid.value = 1
    dut.key_is_test.value = 1
    dut.key_l4_dst.value = 50001
    dut.key_l3_proto.value = 17
    dut.key_flow_id.value = 42
    await settle(dut)
    assert dut.res_hit.value == 0


@cocotb.test()
async def test_test_rx_hit(dut):
    disable_all(dut)
    load_table(
        dut,
        [
            ClassifierEntry(
                enable=True,
                action=ACT_TEST_RX,
                priority=5,
                flow_id=42,
                l4_dst=50001,
                l3_proto=17,
                mask_l4_dst=True,
                mask_l3_proto=True,
                mask_is_test=True,
                mask_flow_id=True,
            ),
            ClassifierEntry(),
            ClassifierEntry(),
            ClassifierEntry(),
        ],
    )
    dut.key_valid.value = 1
    dut.key_is_test.value = 1
    dut.key_l4_dst.value = 50001
    dut.key_l3_proto.value = 17
    dut.key_flow_id.value = 42
    await settle(dut)
    assert dut.res_hit.value == 1
    assert int(dut.res_action.value) == ACT_TEST_RX
    assert int(dut.res_flow_id.value) == 42


@cocotb.test()
async def test_priority_winner_lowest(dut):
    """Two enabled entries both match; the lower priority value wins."""
    disable_all(dut)
    load_table(
        dut,
        [
            ClassifierEntry(
                enable=True, action=ACT_PUNT, priority=20,
                l3_proto=17, mask_l3_proto=True,
            ),
            ClassifierEntry(
                enable=True, action=ACT_TEST_RX, priority=5,
                l3_proto=17, flow_id=99, mask_l3_proto=True,
            ),
            ClassifierEntry(),
            ClassifierEntry(),
        ],
    )
    dut.key_valid.value = 1
    dut.key_is_test.value = 0
    dut.key_l4_dst.value = 0
    dut.key_l3_proto.value = 17
    dut.key_flow_id.value = 0
    await settle(dut)
    assert dut.res_hit.value == 1
    assert int(dut.res_action.value) == ACT_TEST_RX
    assert int(dut.res_flow_id.value) == 99


@cocotb.test()
async def test_disabled_row_ignored(dut):
    """Disabled entry must not match even if all fields agree."""
    disable_all(dut)
    load_table(
        dut,
        [
            ClassifierEntry(
                enable=False, action=ACT_TEST_RX, priority=1,
                l4_dst=50001, mask_l4_dst=True,
            ),
            ClassifierEntry(),
            ClassifierEntry(),
            ClassifierEntry(),
        ],
    )
    dut.key_valid.value = 1
    dut.key_is_test.value = 0
    dut.key_l4_dst.value = 50001
    dut.key_l3_proto.value = 17
    dut.key_flow_id.value = 0
    await settle(dut)
    assert dut.res_hit.value == 0


@cocotb.test()
async def test_wildcard_via_mask(dut):
    """Entry with all mask bits clear matches any valid key."""
    disable_all(dut)
    load_table(
        dut,
        [
            ClassifierEntry(enable=True, action=ACT_PUNT, priority=200),
            ClassifierEntry(),
            ClassifierEntry(),
            ClassifierEntry(),
        ],
    )
    dut.key_valid.value = 1
    dut.key_is_test.value = 0
    dut.key_l4_dst.value = 12345
    dut.key_l3_proto.value = 6
    dut.key_flow_id.value = 7
    await settle(dut)
    assert dut.res_hit.value == 1
    assert int(dut.res_action.value) == ACT_PUNT


@cocotb.test()
async def test_invalid_key_never_hits(dut):
    """key_valid==0 -> classifier never fires."""
    disable_all(dut)
    load_table(
        dut,
        [
            ClassifierEntry(enable=True, action=ACT_PUNT, priority=1),
            ClassifierEntry(),
            ClassifierEntry(),
            ClassifierEntry(),
        ],
    )
    dut.key_valid.value = 0
    dut.key_is_test.value = 0
    dut.key_l4_dst.value = 0
    dut.key_l3_proto.value = 0
    dut.key_flow_id.value = 0
    await settle(dut)
    assert dut.res_hit.value == 0
