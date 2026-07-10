# Phase 3 FPGA build — known Vivado warnings (triaged)

Run `report_methodology` / `report_cdc` on the routed checkpoint
(`build/.../impl_1/pwfpga_top_phase3_board_routed.dcp`). The items below are
**known and intentionally not fixed** — treat anything *not* on this list as new
and worth investigating. Waivers live in `xdc/phase3_cdc.xdc`.

## Waived (intentional, scoped exceptions)

| ID | Where | Why it's safe / why waived |
|----|-------|----------------------------|
| **CDC-10** ×2 | reset-source merges: `axi_aresetn & mmcm_lock` → `dp_rstn_sync`; `!rst_n_100 \|\| !mmcm_lock` → SFP ctrl reset sync | MMCM lock-loss must **async-assert** reset, but the dependent clock is the MMCM's own output and stops on lock loss — the assert cannot be synchronised. The gate drives only the synchroniser's async-assert; deassert is 2-FF synchronised; a merge glitch only over-asserts (safe). |
| **TIMING-6 / TIMING-7** | timestamp Gray-CDC clock pairs, **two CDCs**: the egress stamp `dp_clk_u → gtwiz_userclk_tx_srcclk_out[0]/[0]_1` (`u_tscdc`, per port) **and** the RX ingress wire-stamp `dp_clk → each MAC `sfp_rx_clk`` (`u_rxtscdc`, per port; `pw_ts_gray_cdc`) | Intentionally asynchronous (different clock sources, no common primary clock). Each crossing is constrained per-port by `set_max_delay -datapath_only` + `set_bus_skew` (see `xdc/phase3_cdc.xdc`). Waived **scoped to exactly these clock pairs** (not a clock_groups, which would also drop the max_delay/bus_skew), so a real unconstrained-clock Critical elsewhere still stands out. |

## Known, left as-is (non-blocking)

| ID | Count | What / why not fixed | Re-evaluate if… |
|----|------:|----------------------|-----------------|
| **LUTAR-1** | 11 (Warning) | "LUT drives async reset alert" — a multi-input LUT feeds an async preset/clear pin (can glitch → spurious reset). **Not** hash-DSP related. OURS: the two intentional reset-source merges (`!rst_n_100 \|\| !mmcm_lock` → SFP reset-sync `/PRE`; `axi_aresetn & mmcm_lock` → `dp_rstn_sync`), also waived as **CDC-10** above — required so an MMCM lock-loss async-asserts reset (the dependent clock stops on lock loss); deassert is synchronised; a glitch only *over*-asserts (safe). The rest are PCIe / SFP-GT **vendor IP** reset LUTs. | a LUTAR-1 appears **outside** these reset merges / vendor IP — a real glitchy reset LUT in our logic. |
| **DPIR-2** + **SYNTH-10** | 94 + 6 (Warning) | Hash-classifier DSP (`u_hclass/hash_index` multiply) — this is where the hash-DSP packing lives. DPIR-2 "Asynchronous driver check": the masked-key / seed registers feeding the DSP have async reset, blocking DSP **input-register packing** (DSP regs are sync-reset only). SYNTH-10 "Wide multiplier": the 32×32 hash multiply. **Optimisation hints only — no timing/functional impact** (dp_clk meets timing). `mkey_q1` (A operand) is now reset-less, cutting some; the **seed (B operand) keeps its reset** and an **XOR fold sits between the key reg and the DSP**, so packing still won't happen. | dp_clk timing or LUT pressure forces it → make the hash-seed CSR reset-less **and** register `k32` at the DSP A input (past the fold). |
| **TIMING-9** | 1 (Warning) | "Unknown CDC Logic" — Vivado couldn't classify one crossing's structure. Low priority but **unexplained**; locate it (`report_cdc -details`) before the next sign-off rather than waiving blindly. | (treat as to-investigate, not a settled waiver.) |
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
