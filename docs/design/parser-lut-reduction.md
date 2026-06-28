# Design memo: parser LUT reduction (to make room for TCP / Part C)

**Status: SUPERSEDED — this refactor is NOT what unblocked TCP, and the variant
that was tried did not work.** Stateless TCP (Part C) has SHIPPED and is
HW-validated. The LUT lever that freed the room was NOT the parser refactor below
— it was **moving the flow-table CSR staging from a register double-buffer to
BRAM** (a word-serial commit walk; see `rtl-modules.md`, `pw_flow_table_bram`),
which freed ~15.7K LUT (84.6% → 74.9%) AND improved dp_clk WNS. With that headroom
A+B+C built at LUT 84.4%, then HDR_BYTES was raised back to **176** (deepest
v6-encap TCP RX) at LUT 83.5% / WNS +0.082, all HW-validated.

A parser variant of the idea below — eliminating the full `window_o[HDR_BYTES]`
output and emitting only an inner-relative slice — WAS built and **abandoned**: it
gave **no LUT reduction** (~84%, synthesis already shares the `eff` decode across
the scattered reads) and **broke timing** (-1.874 ns: fusing two variable barrel
shifts into one Stage-A2 cone). See `dp-clk-timing-lessons` memory UPDATE 11/12.
**Conclusion: the parser is NOT a LUT lever on this device; the register-array →
BRAM transform is.** The notes below are kept only as a record of the original
(invalidated) plan.

---

## (Original — invalidated — notes below)

## Where the LUT goes

`pw_parser_axis` is the biggest block (~36–39 K LUT across 2 ports). Its dominant
cost is the **variable-offset byte muxes**: the test-header / L3 / L4 fields are
read as `hdrA[eff + N]` where `eff` is a *runtime* base (it shifts with VLAN
presence and encapsulation depth — outer IP, GRE/IPIP/EtherIP, inner L2, inner
IP). Every such `hdrA[eff + N]` is a `HDR_BYTES`-wide byte mux, and there are many
(addresses, ports, proto, the 28–32 B test region). Cost scales ~linearly with
`HDR_BYTES`.

`HDR_BYTES` is therefore the dominant lever:
- It was cut **160 → 128** for the A+B work (freed ~9 K LUT, closed timing). Cost:
  RX test-header classification now spans ≤128 B (loses the deepest v6-in-v6
  encap RX; TX generation unaffected).
- TCP pushes the *deepest* test header to ~166 B (Eth14 + VLAN4 + outer v6 40 +
  EtherIP16 + inner v6 40 + TCP20 + 32 test = 166), which would force `HDR_BYTES`
  back UP to ~176 — the opposite direction. So "just raise HDR_BYTES" is a
  non-starter; the muxes must get structurally cheaper.

## The structural fix: a fixed-offset inner window

Today every field mux spans the full `HDR_BYTES` because `eff` can land anywhere.
Instead, **re-base once**:

1. Compute the inner-L3 start (`eff`) as today (after VLAN + any encap), in the
   stage that already does this.
2. **Register a small fixed-size inner window** — copy `hdrA[eff +: INNER_W]` into
   `inner[0 .. INNER_W-1]` once (`INNER_W` ≈ 60: inner IP 40 + L4 20, or +32 for
   the test region if it's read from the inner window too). This is ONE variable
   shift of a narrow window, not N variable muxes over the wide buffer.
3. Read all inner fields as **fixed** offsets into `inner[]` (`inner[9]` = proto,
   `inner[16..19]` = v4 dst, `inner[udp_off+2]` = l4 dst, …). Fixed offsets
   synthesise to wires / tiny muxes, not `HDR_BYTES`-wide muxes.

Net: the wide variable muxes collapse to a single windowed shift + cheap fixed
indexing. Expected to free a large fraction of the parser's LUT and *decouple*
the field-extraction cost from `HDR_BYTES`, so the deeper TCP header fits without
blowing area.

### Watch-outs
- The barrel shift `hdrA[eff +: INNER_W]` is itself a mux; keep `INNER_W` minimal
  and pipeline it (the parser already has stage A/A2/B registers to land it in).
- Keep the outer/encap field captures (proto, GRE/EtherIP selectors) where they
  are — they read the *outer* header at small fixed offsets already.
- The flow-id map + hash + field classifier consume the registered key, not the
  raw window, so they're unaffected by the re-base (validate alignment with
  tb_data_plane_axis + a HW header-classify loopback, as the hash-pipeline change
  did).

## Order of operations to revive TCP
1. Implement the fixed inner-window re-base above; confirm LUT drop + timing on a
   build (target: enough headroom that A+B+**C** routes with margin).
2. Raise `HDR_BYTES` only as far as the *re-based* design needs (likely far less
   than 176, since fields now come from `inner[]`).
3. Rebase `phase3-tcp-gen` onto this; forward-port its A+B review fixes
   (comparator dedup, random-salt test) that post-date the branch.
4. Re-run the C-side checks (ref-checksum TB, tb_ts_insert TCP fold, deepest-encap
   loopback) + the two-gated-build timing flow.

See [[dp-clk-timing-lessons]] (memory) for the at-ceiling build behaviour and the
HDR_BYTES lever history.
