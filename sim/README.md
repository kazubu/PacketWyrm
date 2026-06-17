# PacketWyrm RTL simulation

SystemVerilog testbenches driven by Verilator. The full sweep:

```sh
cd sim
make sim_all       # all 18 testbenches; ~425 assertions total
make wave          # rebuild sim with FST tracing -> sim_build/data_plane.fst
make clean
```

For a Scapy + Python-asserted unit sweep at the spec level, see
`sim/cocotb/` (Icarus-driven, 17 assertions across parser /
classifier / flow_gen behavioural mirrors).

## Individual targets

| Target        | Testbench                       | Assertions | What it proves                                                          |
|---------------|---------------------------------|-----------:|-------------------------------------------------------------------------|
| `make sim`    | `data_plane_tb/`                | 38         | parser + classifier + flow_gen + test_rx_checker end-to-end             |
| `make sim_axis` | `axis_serial_tb/`             | 16         | wide<->64-bit AXIS serializer / deserializer round-trip (MAC interface) |
| `make sim_csr`  | `csr_tb/`                     | 24         | AXI-Lite CSR window (classifier table) decode + W1C + commit            |
| `make sim_flow` | `flow_window_tb/`             | 16         | flow-template CSR window                                                |
| `make sim_stats`| `stats_snapshot_tb/`          | 16         | per-flow stats counters + snapshot trigger semantics                    |
| `make sim_lat`  | `lat_histogram_tb/`           | 16         | BRAM-backed per-flow latency histogram: accumulate, live read, clear    |
| `make sim_pax`  | `parser_axis_tb/`             | 112        | 64-bit streaming parser key extraction (2-stage), 102 protocol/offset keys |
| `make sim_fga`  | `flow_gen_axis_tb/`           | 10         | single AXIS flow generator frame emission (legacy single-slot path)     |
| `make sim_fgm`  | `flow_gen_multi_tb/`          |  5         | N-slot round-robin multi-flow generator (token buckets, per-slot flow_id) |
| `make sim_saf`  | `frame_saf_tb/`               | 23         | store-and-forward buffer: whole-frame buffering, route tag + metadata, backpressure/drop |
| `make sim_punt` | `punt_window_tb/`             | 18         | punt RX window: capture frame + metadata, CSR readback, pop, overflow |
| `make sim_dpa`  | `data_plane_axis_tb/`         | 43         | 64-bit streaming data plane end-to-end (parser->classifier->SAF->checker; FORWARD/PUNT+lif/loopback) |
| `make sim_spi`  | `spi_flash_tb/`               |  5         | CSR SPI byte engine: loopback + behavioural-flash program/read-back     |
| `make sim_icap` | `icap_reboot_tb/`             |  9         | ICAP IPROG command stream (sync / WBSTAR / IPROG, bit-swapped)          |
| `make sim_tsi`  | `ts_insert_tb/`               | ~25        | egress tx_ts overwrite: no-VLAN / VLAN offsets, magic-gated passthrough |
| `make sim_full` | `csr_full_tb/`                | 12         | `pw_csr_full` AXI-Lite slave integrating all four windows               |
| `make sim_top`  | `phase3_top_tb/`              | 10         | `pwfpga_top_phase3`: AXI-Lite -> CSR -> flow_gen -> AXIS loop -> RX; ARP PUNT drained via the punt window over CSR |
| `make sim_vec`  | `wire_vectors_tb/`            | 25         | C `pw_bar_backend` byte image vs SV `pw_csr_full` decoder agree         |

## Quick tour of the data plane scenarios (`make sim`)

`data_plane_tb/tb_data_plane.sv` exercises
`rtl/phase3/pw_data_plane.sv` (with `pw_parser`, `pw_classifier`,
`pw_test_rx_checker`, `pw_flow_gen` underneath):

1. **drop** &mdash; UDP/IPv4 on port 0 with no rule -> default DROP;
   per-port drop counter ticks.
2. **punt** &mdash; classifier rule on `ethertype == 0x0806` punts an
   ARP frame to the `punt` channel.
3. **loopback** &mdash; TEST_RX rule + enabled flow_gen on port 0;
   `tx[0]` is wired back into `rx[1]`; checker reports `rx > 0,
   lost == 0`.
4. **loss** &mdash; explicit injection with a 5-packet sequence gap;
   `lost == 5`.
5. **dup** &mdash; replay the previous sequence number; duplicate
   counter ticks.

Plus QinQ, IPv6, TCP, ICMP/ICMPv6, OSPF, FORWARD_PORT, out-of-order,
rate, mask-based matching, and latency-histogram scenarios layered in
on top of the original five.

## Wire-vector regression (`make sim_vec`)

`make sim_vec` is the C&harr;SV agreement test: a Python harness
calls into the real `libpacketwyrm` BAR backend, captures the
post-write 128 KiB BAR image as hex, and replays it into the
SystemVerilog `pw_csr_full` decoder. If the C struct layout, the
backend's byte ordering, or the SV CSR window field encoding ever
drift, this fails. 25 scenarios.

## Lessons learned (Verilator quirks)

Two real Verilator behaviours caught us during early Phase 3 work;
the workarounds are still in tree and called out where they bit, so
future RTL doesn't relearn them:

1. **Continuous assigns to unpacked-array elements may not
   propagate.** `logic [7:0] hdr [0:99]; assign hdr[12] = ...;`
   silently produced 0. Same code with a packed array
   (`logic [99:0][7:0] hdr;`) works. Keep all internal byte-array
   intermediates packed; unpacked is only for the testbench-visible
   `pw_frame_t` array of ports.
2. **`always_comb` / `always @*` did not auto-sense packed-array
   element changes driven by a chain of continuous assigns from a
   packed-byte-array port.** The combinational parser produced zero
   output. Fix: do the parsing inside `always_ff @(posedge clk)`
   (1-cycle latency) and:
   - register outputs into a *local* `logic` then `assign` them out
     (procedural assignment to a typedef'd struct output port
     silently fails to update the port);
   - downstream uses the parser's registered `key_valid_o`, not the
     raw `rx_valid_i`.

Both reproduce on Verilator 5.020 (Debian 5.020-1) and may not
appear on other simulators. The RTL we ship works on Verilator and
should synthesise cleanly on Vivado.

## Future testbenches

- Use the existing shared SV packet builders (Eth/VLAN/QinQ/IPv4/
  IPv6/TCP/UDP/test-header) instead of writing new ones.
- Avoid functions that return wide packed structs; tasks with
  `output` arguments or direct member access work better under
  Verilator.
- For new protocol coverage, extend `pw_parser` first (add fields to
  `pw_match_key_t`), then add scenarios.
- For Python-level unit tests with Scapy frame builders, target
  `sim/cocotb/` instead of inventing another SV harness.
