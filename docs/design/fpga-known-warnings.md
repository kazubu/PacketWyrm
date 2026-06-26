# Phase 3 FPGA build — known Vivado warnings (triaged)

Run `report_methodology` / `report_cdc` on the routed checkpoint
(`build/.../impl_1/pwfpga_top_phase3_board_routed.dcp`). The items below are
**known and intentionally not fixed** — treat anything *not* on this list as new
and worth investigating. Waivers live in `xdc/phase3_cdc.xdc`.

## Waived (intentional, scoped exceptions)

| ID | Where | Why it's safe / why waived |
|----|-------|----------------------------|
| **CDC-10** ×2 | reset-source merges: `axi_aresetn & mmcm_lock` → `dp_rstn_sync`; `!rst_n_100 \|\| !mmcm_lock` → SFP ctrl reset sync | MMCM lock-loss must **async-assert** reset, but the dependent clock is the MMCM's own output and stops on lock loss — the assert cannot be synchronised. The gate drives only the synchroniser's async-assert; deassert is 2-FF synchronised; a merge glitch only over-asserts (safe). |
| **TIMING-6 / TIMING-7** ×2 each | timestamp Gray-CDC clock pairs `dp_clk_u → gtwiz_userclk_tx_srcclk_out[0]/[0]_1` (`u_tscdc`) | Intentionally asynchronous (different clock sources, no common primary clock). The crossing is constrained per-port by `set_max_delay -datapath_only` + `set_bus_skew`. Waived **scoped to these two pairs only** (not a clock_groups, which would also drop the max_delay/bus_skew), so a real unconstrained-clock Critical elsewhere still stands out. |

## Known, left as-is (non-blocking)

| ID | Count | What / why not fixed | Re-evaluate if… |
|----|------:|----------------------|-----------------|
| **LUTAR-1** | 11 (Warning) | Hash-classifier DSP (`hash_index` multiply). The key + seed registers feeding the multiply have async reset, blocking DSP input-register absorption. `mkey_q1` (A operand) is now reset-less; the **seed (B operand) keeps its reset** and an **XOR fold sits between the key reg and the DSP**, so the DSP can't pack regardless. Perf/area hint only — no timing or functional impact. | dp_clk timing or LUT pressure forces it → make the hash-seed CSR reset-less **and** register `k32` at the DSP A input (past the fold). |
| **DPIR-2** | 94 (Warning) | "Asynchronous driver check" on the intentional CDC paths (gray timestamp, link-status sync, MAC↔dp FIFO). Expected; covered by `ASYNC_REG` + `set_max_delay`/`set_bus_skew`/`set_false_path`. | A DPIR-2 appears on a path with **no** ASYNC_REG / max_delay / false_path → that's a real unconstrained CDC. |
| **CDC-10** | 2 (Critical, `report_cdc`) | **Inside the Taxi GT vendor IP** (`gt_rx_reset_inst` `rx_reset_done → rx_reset_sync`). Vendor-owned, pre-existing, unmodified by our work. Left **unwaived** — we don't assert a safety claim on un-vetted third-party IP internals. | Taxi is updated, or a board bring-up issue points here. |

## Clean (must stay clean)

- All on-chip functional clocks meet timing: **dp_clk WNS ≥ 0** (read post-route;
  the project tcl has no timing gate — `write_bitstream completed` ≠ closed).
- Our reset levels are registered / glitch-free: **no combinational logic on the
  async-reset pins** of our own logic. The two reset-source merges above are the
  single documented exception (and are async-assert-only).
- `report_cdc`: the egress soft-flush and timestamp CDC show as synchronised
  (ASYNC_REG) with explicit constraints; no *unwaived* combinational-before-sync
  in our RTL.
