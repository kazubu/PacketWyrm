# DMA slow-path (host ⇄ FPGA frame movement)

Status: **DESIGN / proposed** (2026-07-03). Replaces the CSR-window inject/punt
slow path. Prompted by the cRPD 2-node lab: control-plane punt/inject works, but
the register-copy windows cap frames at **512 B inject / 2048 B punt** and add
~200 ms latency — IS-IS (MTU-padded hellos + LSPs), 1500 B data, and jumbo all
fail. See [[port-drops-icmpv6-tap]] context and `configs/examples/lab-crpd-2node/`.

## 1. Problem with the current slow path

Today (`pw_inject_tx_window` / `pw_punt_rx_window` + `backend_bar.c`):

- The host copies a frame **word-by-word through a CSR BAR window** (register
  writes/reads), one 32-bit MMIO per 4 bytes, then polls a busy/valid bit.
- Frame size is bounded by a small on-FPGA BRAM buffer mapped into the 64 KB
  BAR: **inject `BUF_BYTES=512`**, **punt `BUF_BEATS=256` = 2048 B**.
- The 64 KB BAR is full; jumbo windows (2×9216 B) do not fit without expanding
  the BAR to 128 KB (17-bit AXI-Lite, PCIe IP regen) — rejected as too invasive.
- MMIO-per-word + poll ⇒ ~200 ms round trips; unusable for real routing traffic.

This is the wrong mechanism: **packet data does not belong in config/register
space.** The correct mechanism is DMA — the FPGA moves frames to/from host RAM
over PCIe using descriptor rings, and the BAR carries only doorbells/indices.

## 2. Goal & requirements

- **Full frame size**: up to MTU 9000 (≈9018 B on the wire; ring buffers sized
  for jumbo). No CSR-window size ceiling.
- **Throughput/latency**: bulk DMA, not MMIO-per-word; target ≫ enough for
  routing control planes and moderate host data (orders of magnitude over today).
- **Works under vfio-pci** (Secure Boot / kernel lockdown — the production path).
  Plain sysfs `resource0` mmap **cannot** DMA (no IOMMU IOVA); DMA is vfio-only.
- **Keep the CSR BAR unchanged** (all existing register access, stats, flash,
  classifier programming stay exactly as-is).
- **Preserve slow-path metadata**: punt carries `logical_if_id` + ingress port +
  RX wire timestamp; inject carries egress port (+ TX wire timestamp back).
- **Fit the FPGA**: LUT is at **83.98 % (136 647 / 162 720)** — new RTL must be
  lean. BRAM is comfortable (30 % used). Timing: dp_clk WNS margin is small;
  the DMA glue should sit on the 250 MHz `axi_aclk` PCIe domain, pipelined.

## 3. Two candidate architectures

The PCIe core today is the **Xilinx XDMA IP** (`pcie_gen3_wrapper`,
`functional_mode=DMA`, Gen3 x8, 256-bit, 250 MHz), exposing:
- `m_axil_*` — AXI-Lite master → our 64 KB CSR BAR (**keep**).
- `m_axi_*` — 256-bit AXI-MM master (the XDMA H2C/C2H data mover into card
  space) — **currently tied off** in `fpga/as02mc04/src/pcie_axi_lite_bridge.sv`.
- XDMA's own descriptor engine (H2C = host→card, C2H = card→host), driven by the
  host via XDMA control registers + descriptor rings in host memory.

### Approach A — reuse the XDMA IP (recommended)

Wire up the XDMA H2C/C2H data movers that are already in the instantiated IP.
Two sub-variants for how frames reach the data-plane AXIS:

- **A1 (AXI-MM + bridge):** keep XDMA in MM mode; attach a small card-side packet
  BRAM on `m_axi`; add MM↔AXIS shims to `pw_inject_tx_window`/`pw_punt_rx_window`
  AXIS ports. No IP regen. More card-side glue (MM slave + descriptor coord).
- **A2 (AXI-Stream):** reconfigure XDMA for AXI-Stream H2C/C2H (IP regen, no BAR
  change); H2C AXIS drives inject directly, punt AXIS drives C2H. Cleanest RTL
  (no card-side buffer), but re-generates the PCIe IP (timing re-close risk).

Host side (both): drive the XDMA descriptor engine from userspace over vfio
(XDMA C2H/H2C descriptor format, PG195), rings in `VFIO_IOMMU_MAP_DMA`-mapped
host buffers.

**Pros:** least new FPGA logic (best for the 84 % LUT budget); CSR BAR untouched;
IP already present. **Cons:** driving XDMA descriptors from userspace/vfio (no
`xdma.ko`) is fiddly; A2 needs an IP regen.

### Approach B — taxi DMA engine (Corundum-style)

Replace the XDMA IP with a bare `pcie4_uscale_plus` hard block + the vendored
taxi DMA stack: `taxi_pcie_us_axil_master` (CSR BAR via CQ/CC),
`taxi_dma_if_pcie_us` (RQ/RC), and `taxi_dma_client_axis_sink`/`_source` for
punt/inject. Descriptor/ring contract is taxi's (`taxi_dma_desc_if`:
`req_src_addr`/`req_dst_addr`/`req_len`/`req_tag`; `sts_*`), documented and
simpler than XDMA's. `cndm_proto/rtl/cndm_proto_pcie_us.sv` is a full worked
integration.

**Pros:** clean, documented ring contract; AXIS clients map 1:1 onto punt/inject;
open-source, inspectable. **Cons:** **replaces the PCIe IP** (re-do the CSR BAR
path, board wrapper, IP config) — the biggest RTL change and highest timing/
bring-up risk; more new LUT (DMA engine + AXIL master) against a tight budget.

### Recommendation — **A2 (XDMA AXI-Stream), chosen 2026-07-03**

Correction to an earlier draft that recommended A1 as "no IP regen": the
generated IP has the **XDMA control BAR disabled** (`pcie_gen3_wrapper.xci`:
`pciebar2axibar_xdma enabled=false`; only `pciebar2axibar_axil_master` = the CSR
BAR is enabled). XDMA's DMA engine (SGDMA descriptor/channel registers) is
reachable **only** through that control BAR, so the DMA engine cannot be driven
today — enabling it is an **IP reconfiguration + regen regardless of A1 vs A2**.

Since a regen is required either way, **A2 wins**: for the same regen cost it
gives the leanest RTL (H2C AXIS drives inject, punt drives C2H AXIS directly — no
card-side packet buffer, no MM↔AXIS bridge, best for the 84 % LUT budget). A1
would add a card-side buffer + MM↔AXIS shim + descriptor coordination for no
benefit. B (replace the IP with taxi) stays in reserve if XDMA userspace
descriptor control proves impractical.

**A2 IP changes** (`fpga/as02mc04/ip/pcie_gen3.tcl`, validate keys via
`ip/probe_xdma.tcl` on Vivado 2025.2): enable the XDMA control BAR
(`pciebar2axibar_xdma`), select AXI-Stream H2C/C2H interface, keep the AXI-Lite
master CSR BAR unchanged. The host reaches the XDMA channel/SGDMA registers via
the newly-enabled control BAR (mmap'd under vfio); descriptor rings live in
`VFIO_IOMMU_MAP_DMA`-mapped host memory.

## 4. Ring / descriptor contract (host ⇄ FPGA)

Two rings in `VFIO_IOMMU_MAP_DMA`-mapped host memory (power-of-two entries):

- **RX ring (punt, C2H):** FPGA writes each punted frame into a host frame
  buffer + a completion descriptor: `{ iova, len, logical_if_id, ingress_port,
  rx_ts, status }`. Host consumes at `consumer_idx`, FPGA produces at
  `producer_idx`; a BAR doorbell/index register pair per ring.
- **TX ring (inject, H2C):** host writes a frame into a buffer + a descriptor
  `{ iova, len, egress_port }`, bumps the TX producer doorbell; FPGA DMAs the
  frame and emits it on the egress port's TX arbiter, writing back a completion
  (+ TX wire timestamp) the host reaps.

`struct pwfpga_dma_desc` / `pwfpga_dma_cpl` already exist in `csr.h` (defined,
unused) — extend to carry `logical_if_id` / `egress_port` / `timestamp` / `status`
and add the ring-control CSR block (ring base IOVA, size, head/tail doorbells) in
a small **new CSR window** (registers only — the *data* is in host RAM, so this
costs almost no BAR space, unlike today's frame windows). Gate on a new
`PWFPGA_CAP_HAS_DMA` capability bit so software auto-selects DMA when present and
falls back to the CSR-window path otherwise.

## 5. Touchpoints

**RTL** (`rtl/phase3/`, `fpga/as02mc04/`):
- `pcie_axi_lite_bridge.sv`: expose the tied-off `m_axi_*` (A1) or regen XDMA for
  AXIS (A2).
- New `pw_dma_slowpath.sv`: TX/RX descriptor-ring engines + MM↔AXIS shims onto the
  existing `pw_inject_tx_window`/`pw_punt_rx_window` AXIS ports (or replace those
  windows' BRAM buffers with the DMA path).
- New DMA ring-control CSR window + `pw_csr_full`/`pwfpga_top_phase3` wiring; set
  `PWFPGA_CAP_HAS_DMA`.
- CDC: rings on `axi_aclk` (250 MHz), data-plane AXIS on `dp_clk` (156.25) — reuse
  the existing AXIS CDC pattern.

**SW** (`sw/libpacketwyrm/`):
- `vfio.c`: add `VFIO_IOMMU_MAP_DMA`/`UNMAP` wrappers (container/IOMMU already set
  up — this is the main new plumbing).
- New DMA-mode `slow_path_rx`/`slow_path_tx` (ring enqueue/reap) — same
  `pw_card_backend_ops` signatures, so `pw_host_plane_step` is **unchanged**.
- Ring + frame-buffer allocation (`posix_memalign` + map); `csr.h` ring-control
  offsets + `pwfpga_dma_desc/_cpl` extension; capability-gated backend selection.

**Docs/sim/build:** this doc + `csr-map.md`/`rpc-protocol.md`(n/a)/`CHANGELOG`;
new sim tb for the ring engine (loopback: TX ring → AXIS → RX ring); gated build
(WNS ≥ 0 all clocks) + reflash + HW bring-up.

## 5a. A2 IP config — VALIDATED (2026-07-03, probe_xdma_stream.tcl)

Confirmed on Vivado 2025.2 / xcku3p by generating the instantiation template with
`CONFIG.xdma_axi_intf_mm=AXI_Stream` (base config otherwise identical to
production). Accepted; resulting ports:

- **`m_axis_h2c_tdata_0[255:0]`** + `tkeep_0[31:0]`/`tlast_0`/`tvalid_0`/`tready_0`
  — host→FPGA stream (H2C) = **inject** source.
- **`s_axis_c2h_tdata_0[255:0]`** + `tkeep_0[31:0]`/`tlast_0`/`tvalid_0`/`tready_0`
  — FPGA→host stream (C2H) = **punt** sink.
- `m_axil_*` (32-bit AXI-Lite CSR master) — **unchanged** (keep our CSR path).
- `usr_irq_req/ack[0:0]` — 1 user IRQ available (poll first; wire later).
- One H2C + one C2H channel (`H2C_XDMA_CHNL`/`C2H_XDMA_CHNL`), 256-bit @ 250 MHz.
- Set `CONFIG.xdma_axilite_slave=false` (we don't need the AXI-Lite slave).

`pcie_gen3.tcl` deltas vs today: add `CONFIG.xdma_axi_intf_mm {AXI_Stream}` and
`CONFIG.xdma_axilite_slave {false}`; keep `functional_mode DMA` + `axilite_master`
CSR. **No control-BAR enable key is needed** — see the BAR-layout note below.

### 5a-bis. BAR layout — VERIFIED (2026-07-04, probe_xdma_bars.tcl) — **P2 gate**

Enumerated the generated IP for the production AXI-Stream config:
- **`pf0_bar0` = 128 KB, Memory, enabled** (the only enabled BAR). Decoding the
  apertures: `PF0_BAR0_APERTURE_SIZE = 0x0A` (128 KB) = `XDMA_APERTURE_SIZE = 0x09`
  (64 KB) **+** `AXILITE_MASTER_APERTURE_SIZE = 0x09` (64 KB). So enabling the DMA
  engine grows BAR0 to 128 KB and **splits it**: the XDMA DMA/SGDMA control
  register block occupies **[0, 64 KB)** and the AXI-Lite-master **CSR window moves
  to [64 KB, 128 KB) (offset `0x10000`)**. (In the old MM-mode config the DMA
  engine BAR was not enabled and the CSR sat at BAR0 offset 0.)
- `pciebar2axibar_xdma` is a **disabled parameter** (setting it `true` is ignored,
  Vivado WARNING 19-3374). It is the AXI-MM-bypass address translation, irrelevant
  in AXI-Stream mode — it is **not** the descriptor-engine enable, and the DMA
  register block is present regardless (it lives in BAR0[0,64 KB)). Hence no Tcl
  change to expose it.

**P2 host-side consequences (gate before/at P2 bring-up):**
1. The host CSR base must be offset by **`+0x10000`** within BAR0 when `HAS_DMA`
   (the AXI-Lite-master CSR is in the upper half now). The **current daemon, which
   reads BAR0 at offset 0, will NOT work against this bitstream** — it would read
   the XDMA DMA registers as if they were CSRs. **Do not flash this build until the
   P2 host driver applies the CSR offset** (capability-gated). Confirm the live
   split at bring-up via the vfio region dump / `lspci -v` BAR size (expect 128 KB).
2. The XDMA descriptor/channel/SGDMA registers are at **BAR0[0, 64 KB)** — the P2
   driver programs H2C/C2H descriptors there (PG195 layout). `usr_irq` = 1 wired
   (poll first per §8).

**Domain-crossing glue (the core of `pw_dma_slowpath`):** XDMA streams are
**256-bit @ 250 MHz (`axi_aclk`)**; the data-plane inject/punt AXIS is **64-bit @
156.25 MHz (`dp_clk`)**. So the engine needs width conversion (256↔64) + async CDC
each direction. Per-frame metadata rides an **in-band header** (§9) prepended on
punt (FPGA writes lif_id/ingress/rx_ts ahead of the frame) and consumed on inject
(host prepends egress port; engine strips it before the TX arbiter).

## 5b. P1 integration edit-list (turnkey; atomic — all land together before build)

The slow-path wiring today (mapped): **inject** `pw_inject_tx_window` lives inside
`pw_csr_full` (line ~588) → drives `inj_*_w` → data-plane `s_axis_inj_*`
(pwfpga_top_phase3 ~452). **punt** data-plane `m_axis_punt_*` → `punt_*_w` →
`pw_punt_rx_window u_punt` (core ~344) → CSR read/pop. Chosen integration puts
`pw_dma_slowpath` **inside the core** (least top restructuring): route the XDMA
H2C/C2H streams DOWN into the core as new ports; DMA drives `inj_*_w`, sinks
`punt_*_w`.

1. `ip/pcie_gen3.tcl`: **DONE** — `xdma_axi_intf_mm=AXI_Stream`,
   `xdma_axilite_slave=false`.
2. `src/pcie_axi_lite_bridge.sv`: **DONE** — removed the `m_axi_*` (MM) tie-offs;
   wired the IP's `m_axis_h2c_*_0` / `s_axis_c2h_*_0` (256 b) to new bridge ports;
   kept `m_axil_*` CSR + `usr_irq_req=0`. Exposes H2C(out)/C2H(in) + axi_aclk.
3. `pwfpga_top_phase3.sv` (core): **DONE** — added ports {axi_clk, axi_rst,
   s_h2c_*, m_c2h_*}; instantiated `pw_dma_slowpath u_dma` (axi side ← new ports;
   dp side: `m_inj*`→`inj_*_w` incl. `inj_eg_w`, `s_punt*`←`punt_*_w`; dp_clk=clk,
   dp_rst=~rst_n). `inj_*_w` now driven by `u_dma.m_inj` — the `pw_csr_full`
   inject window outputs are left open and its `inj_m_tready` held low (the window
   stays instantiated inside csr_full; a later cleanup can delete it to recover
   LUTs). Removed `u_punt`; `pw_csr_full.punt_rd_data_i` tied 0.
4. `pwfpga_top_phase3_board.sv`: **DONE** — connected bridge H2C/C2H ↔ core's new
   XDMA ports; passes `axi_aclk` + `~axi_aresetn`.
5. **DONE** — `PW_PHASE3_CAPABILITIES` in `rtl/shared/pw_pkg.sv` now sets
   `PW_CAP_HAS_DMA` (drops the retired `PW_CAP_HAS_PUNT`) → `0x0000_002D`.
6. `project_phase3.tcl`: **DONE** — added `rtl/phase3/pw_dma_slowpath.sv`; the
   taxi source closure now reads `taxi_axis_async_fifo_adapter.f` (superset of
   `taxi_axis_async_fifo.f`, adds `taxi_axis_adapter.sv`).
7. Sims: **DONE** — `tb_phase3_top` drives the new XDMA ports (H2C idle, C2H
   drained) and its punt scenario now checks the punted frame on the C2H stream
   (in-band header `lif_id`/`ingress`) instead of the retired CSR window;
   `TOP_RTL` gained `pw_dma_slowpath.sv` and the `phase3_top` Verilator rule gained
   the taxi `-y` dirs. `make -C sim sim_all` (40 TBs incl. sim_dma, sim_top) PASS.

**P1 status: integration COMPLETE + sim-verified (2026-07-04).** Next: gated build
(WNS ≥ 0 all clocks; **LUT fit is the risk** — two 256-b taxi async-FIFO adapters
vs the 84 % baseline, minus one removed CSR window; the dead csr inject window is a
LUT-recovery lever if it overflows). Reflash 07:00.0, then P2 host driver, then P5
revalidate.

## 6. Phasing

1. **P1 — RTL DMA engine + sim.** `pw_dma_slowpath` + bridge wiring; a Verilator
   tb that loops a TX-ring frame through AXIS into the RX ring. No HW yet.
2. **P2 — Host DMA plumbing.** vfio `MAP_DMA`, buffer/ring alloc, DMA `slow_path_*`
   ops, capability gating. Unit-test the ring logic against a fake/loopback.
3. **P3 — Integrate.** Wire the DMA backend under `pw_host_plane` (no host-plane
   change); keep the CSR-window path as fallback.
4. **P4 — Gated build + HW bring-up.** WNS ≥ 0 all clocks; reflash 07:00.0; debug
   the live DMA datapath (LUT budget check, IOMMU faults, ring stalls).
5. **P5 — Re-validate the cRPD lab at jumbo.** MTU 9000, hello-padding ON, large
   pings, BGP/OSPF/IS-IS all Up; measure latency/throughput vs the old path.

## 7. Risks

- **LUT budget (84 % used).** The DMA engine must be lean; A1 (reuse XDMA) is the
  lowest-LUT option. If it doesn't fit, defer a non-critical block or pick A2.
- **Timing.** New logic on 250 MHz `axi_aclk` (4 ns) needs pipelining; the gated
  build margin is small (recent WNS +0.031). CDC to dp_clk must be clean.
- **vfio DMA under lockdown.** IOMMU group viability + `MAP_DMA` must work on the
  Secure-Boot host; verify no lockdown block on bus-master DMA.
- **XDMA userspace descriptor control.** Driving XDMA's engine without `xdma.ko`
  (over vfio) is the main SW unknown for Approach A; prototype early in P2.
- **Build/flash cycle.** Multi-iteration HW bring-up of a new datapath; each
  gated build + reflash is the long pole.

## 8. Decisions (signed off 2026-07-03)

1. **Approach: A2** (XDMA AXI-Stream + enable the XDMA control BAR). A1's
   "no-regen" premise was false (control BAR disabled); a regen is needed either
   way, so A2's leaner RTL wins. B held in reserve.
2. **Jumbo target: 9216 B** (MTU 9000) ring frame buffers.
3. **Interrupts: poll first** (matches today's `pw_host_plane_step` poll loop);
   XDMA MSI-X later if latency/CPU warrants.

## 9. A2 metadata sideband (design note)

In AXI-Stream mode the H2C/C2H channels carry raw frame bytes; the per-frame
metadata (punt: `logical_if_id`, ingress port, RX wire timestamp; inject: egress
port, TX wire timestamp) is NOT in the byte stream. Options, to settle in P1:
- **C2H completion (`cmpt`) stream** for punt metadata + a small prepended inject
  header consumed by `pw_dma_slowpath` for egress selection; or
- a fixed **N-byte in-band metadata header** prepended to every frame on both
  directions (simplest; costs a few bytes/frame, trivial vs jumbo).
Recommendation: in-band header first (simplest, no extra XDMA stream to wire).
