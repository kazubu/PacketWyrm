# PacketWyrm RTL simulation

A working software-loopback proof of the Phase 3 data plane. Run:

```sh
cd sim
make sim       # build + run the data-plane testbench (38 assertions)
make sim_axis  # round-trip a frame through the wide<->64-bit AXIS
               # serializer/deserializer pair (Phase-2 step toward
               # the production MAC interface). 16 assertions.
make sim_all   # both
make wave      # rebuild with FST tracing, leave sim_build/data_plane.fst
make clean
```

## What the data-plane testbench proves

`data_plane_tb/tb_data_plane.sv` exercises
`rtl/phase3/pw_data_plane.sv` (with `pw_parser`, `pw_classifier`,
`pw_test_rx_checker`, `pw_flow_gen` underneath) through five
scenarios, in order:

1. **drop** &mdash; a UDP/IPv4 frame on port 0 with no matching
   classifier rule hits the default DROP action; the per-port drop
   counter ticks.
2. **punt** &mdash; a classifier rule matching `ethertype == 0x0806`
   is installed; an ARP frame on port 0 emerges on the `punt`
   channel with the right ethertype.
3. **loopback** &mdash; a TEST_RX rule on `udp_dst == 50001 + magic`
   is installed and a flow generator on port 0 is enabled. The
   testbench wires `tx[0]` back into `rx[1]`. After 200 cycles the
   test_rx_checker reports `rx > 0` and `lost == 0`.
4. **loss** &mdash; explicit injection on port 1 with a 5-packet
   gap in the sequence number. `lost == 5` as expected.
5. **dup** &mdash; re-inject the previous sequence number; the
   duplicate counter increments by one.

Sample passing output:

```
[ ok drop] port0 drop: 1
[ ok drop] punt none : 0
[ ok punt] punt valid: 1
[ ok punt] punt ethertype: 2054
[ ok loopback] loopback rx > 0: 1
[ ok loopback] loopback lost : 0
[ ok loopback] loopback ooo  : 0
[ ok loss] pre-gap rx: 5
[ ok loss] pre-gap lost: 0
[ ok loss] post-gap rx: 8
[ ok loss] post-gap lost: 5
[ ok dup] dup count: 1
ALL DATA PLANE SCENARIOS PASS
```

The pipeline this proves end-to-end:

```
rx_frame (1 beat, up to 1536 B)
   |
   v
pw_parser  -- registered key + key_valid (1 cycle latency)
   |
   v
pw_classifier  -- combinational priority match, 8-entry table
   |
   +-> DROP            -> per-port drop counter
   +-> PUNT_TO_HOST    -> punt_frame channel
   +-> MIRROR_TO_HOST  -> (same as PUNT in skeleton)
   +-> FORWARD_PORT    -> tx_frame[egress_port]
   +-> TEST_RX         -> pw_test_rx_checker per-flow counters
                          (rx, lost, dup, out_of_order, last_seq)
```

`pw_flow_gen` emits IPv4/UDP test frames with the PacketWyrm test
header (magic `0xA5027E57`, flow id, sequence, timestamp) at a
configurable rate.

## Lessons learned (Verilator quirks)

Two real Verilator behaviors caught us during this work; we kept
the workarounds and the comments where they bit, so future Phase
3 RTL doesn't relearn them:

1. **Continuous assigns to unpacked-array elements may not
   propagate.** `logic [7:0] hdr [0:99]; assign hdr[12] = ...;`
   silently produced 0. Same code with a packed array
   (`logic [99:0][7:0] hdr;`) works. The fix is to keep all
   internal byte-array intermediates packed; unpacked is only for
   the testbench-visible `pw_frame_t` array of ports.
2. **`always_comb` / `always @*` did not auto-sense packed-array
   element changes driven by a chain of continuous assigns from a
   packed-byte-array port.** The combinational parser produced
   zero output. The fix is to do the parsing inside an
   `always_ff @(posedge clk)` (which gives the parser an explicit
   1-cycle latency). This also requires:
   - the parser registers its outputs into a *local* `logic` and
     `assign`s them out (procedural assignment to a typedef'd-
     struct output port silently fails to update the port);
   - the downstream dispatcher uses the parser's registered
     `key_valid_o` rather than the raw `rx_valid_i` so a 1-cycle
     ingress pulse is captured through the pipeline.

Both behaviors appear in Verilator 5.020 (Debian 5.020-1) and may
not reproduce in other simulators. The RTL we ship works on Verilator
*and* should synthesise cleanly on Vivado (the patterns we adopted
are conservative SystemVerilog).

## Future testbenches

When extending this directory:

- Place packet builders / scenario tasks in shared SV files so
  they can be reused.
- Avoid functions that return wide packed structs; tasks with
  `output` arguments or direct member access work better under
  Verilator.
- For QinQ / IPv6 / TCP, extend `pw_parser` first (add fields to
  `pw_match_key_t`), then add scenarios here.
