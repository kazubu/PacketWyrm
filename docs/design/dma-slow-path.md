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
- **Keep the CSR register map unchanged** (all existing register access, stats,
  flash, classifier programming stay exactly as-is). NB: the register *map* is
  unchanged, but enabling the DMA engine relocates the CSR window's *offset
  within BAR0* to `0x10000` (BAR0 grows to 128 KB — see §5a-bis); the host adds
  that offset when `HAS_DMA`.
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
- **A2 (AXI-Stream):** reconfigure XDMA for AXI-Stream H2C/C2H (IP regen; the CSR
  *register map* is unchanged but BAR0 grows to 128 KB and the CSR window moves to
  offset `0x10000` — see §5a-bis); H2C AXIS drives inject directly, punt AXIS
  drives C2H. Cleanest RTL (no card-side buffer), but re-generates the PCIe IP
  (timing re-close risk).

Host side (both): drive the XDMA descriptor engine from userspace over vfio
(XDMA C2H/H2C descriptor format, PG195), rings in `VFIO_IOMMU_MAP_DMA`-mapped
host buffers.

**Pros:** least new FPGA logic (best for the 84 % LUT budget); CSR *register map*
untouched (only its BAR0 offset moves, §5a-bis); IP already present. **Cons:**
driving XDMA descriptors from userspace/vfio (no `xdma.ko`) is fiddly; A2 needs
an IP regen.

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
production IP runs the XDMA engine in **AXI-MM mode with the MM data mover tied
off**, so switching the H2C/C2H data path to AXI-Stream is an **IP
reconfiguration + regen regardless of A1 vs A2**. Since a regen is required
either way, **A2 wins**: for the same regen cost it gives the leanest RTL (H2C
AXIS drives inject, punt drives C2H AXIS directly — no card-side packet buffer,
no MM↔AXIS bridge, best for the 84 % LUT budget). A1 would add a card-side buffer
+ MM↔AXIS shim + descriptor coordination for no benefit. B (replace the IP with
taxi) stays in reserve if XDMA userspace descriptor control proves impractical.

> NOTE (superseded premise): an earlier draft claimed the DMA engine was
> unreachable because "`pciebar2axibar_xdma enabled=false`". That was wrong —
> `pciebar2axibar_xdma` is the AXI-MM-bypass address translation, not the
> descriptor-engine enable. The DMA/SGDMA control registers live in **BAR0**,
> which is present whenever `functional_mode=DMA`. See §5a-bis (verified): no
> control-BAR enable key is required.

**A2 IP changes** (`fpga/as02mc04/ip/pcie_gen3.tcl`, validate keys via
`ip/probe_xdma_stream.tcl` / `ip/probe_xdma_bars.tcl` on Vivado 2025.2): select
the AXI-Stream H2C/C2H interface (`xdma_axi_intf_mm=AXI_Stream`), drop the unused
AXI-Lite slave (`xdma_axilite_slave=false`), keep `functional_mode=DMA` +
`axilite_master` CSR. **No control-BAR enable key is needed** (§5a-bis). Enabling
the DMA engine grows BAR0 to 128 KB and splits it — XDMA/SGDMA registers at
BAR0[0,64 KB), AXI-Lite CSR at BAR0[64 KB,128 KB) (offset `0x10000`); descriptor
rings live in `VFIO_IOMMU_MAP_DMA`-mapped host memory.

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

### 5a-bis. BAR layout — ⚠️ SUPERSEDED (pre-silicon probe; see §5c point 1)

> **SUPERSEDED — do not follow this section for the CSR offset.** This was a
> *pre-silicon* read of the generated IP (`probe_xdma_bars.tcl`) that predicted a
> single 128 KB split BAR0 with the CSR moved to `+0x10000`. On real silicon
> (2026-07-04) the IP instead exposes **two 64 KB BARs — BAR0 = AXI-Lite CSR at
> offset 0 (UNCHANGED), BAR1 = XDMA control registers** (see §5c point 1). The
> `csr_off = 0` and the `+0x10000` offset is NOT applied; `PWFPGA_CSR_DMA_OFFSET`
> survives only as a probe fallback for a hypothetical future single-big-BAR
> build. The text below is kept for historical context only.

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
(host prepends egress port; engine strips it before the TX arbiter). An inject
header whose egress byte is **out of range (>= PORT_COUNT)** makes the engine
**swallow the whole frame** (consumed, not presented): no TX arbiter would ever
drain such a frame, so presenting it would back up the inject FIFO and wedge the
H2C channel permanently. The full header byte is validated (0x11 does not alias
to port 1). Swallowed frames are not counted (no debug counters in the bridge yet).

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
   dp_rst=`~rst_n | dp_soft_rst` — the bridge flushes with the arbiters/SAFs it
   feeds on the CSR data-plane soft reset; safe one-sided because the taxi async
   FIFO synchronizes each side's reset into the other domain and drops partial
   frames; `PORT_COUNT=NUM_PORTS` for the invalid-egress swallow, §5 above).
   `inj_*_w` now driven by `u_dma.m_inj` — the `pw_csr_full`
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

**P1 status: integration COMPLETE + sim-verified (2026-07-04).**

**Gated build PASSED (2026-07-04, build_id 0x6a47e2bc):** post-route all clocks
positive — axi_aclk 250 MHz WNS +0.257 / WHS +0.012, dp_clk 156.25 +0.272 /
+0.011; "all timing constraints met". **LUT 154316/162720 = 94.84 %** (baseline
83.98 % + ~17.7 k for the two 256-b taxi async-FIFO adapters) — FITS, no
feature-cut. bit+bin under `build/pwfpga_as02mc04_phase3/`. **Flashed 07:00.0 +
HW-validated (2026-07-04)** — see §5c; the pre-flash concern that the CSR would
move to BAR0+0x10000 turned out moot (silicon uses two 64 KB BARs, CSR at BAR0:0).

## 5c. P2 host DMA driver — as-built (SW) + HW bring-up checklist

Implemented in `sw/libpacketwyrm/` — **as-built after HW bring-up** (the design
below reflects the silicon findings in the next section, not the pre-flash draft):
- **`csr.h`**: XDMA register map (H2C/C2H channel + SGDMA blocks, config/irq
  targets), `struct pwfpga_xdma_desc` (32-B SG descriptor + control magic/flags).
  `PWFPGA_CSR_DMA_OFFSET` (0x10000) is retained only as a probe fallback for a
  hypothetical future single-big-BAR; on this build the CSR is BAR0:0 (csr_off=0).
- **`vfio.[ch]`**: `pw_vfio_map_dma`/`unmap_dma` (VFIO_IOMMU_MAP_DMA, identity
  IOVA) for host ring/frame buffers, and `pw_vfio_map_region` to map BAR1 (the
  XDMA control registers) on the already-open device.
- **`backend_bar.c`**: the DMA backend is folded into the existing BAR backend —
  - **Two BARs**: BAR0 = CSR (offset 0, `csr_off=0`, unchanged from legacy);
    **BAR1 = XDMA control registers** (mapped via `pw_vfio_map_region`; `xdma_wr/rd`
    target it). A `DEVICE_ID` probe still self-selects if a future build differs.
  - **`dma_setup`**: maps BAR1 + one page-aligned DMA-mapped pool → {H2C desc,
    C2H descriptor ring[16], TX buf, N RX buffers}. Brought up when **`HAS_DMA`
    && vfio**; if `HAS_DMA` but DMA does NOT come up (sysfs path / failure) the
    attach **FAILS** (fatal — no CSR-window fallback exists), so `pw_bar_backend_open`
    retries via vfio or surfaces the error.
  - **`dma_slow_path_tx`** (H2C, inject): prepend the 8-B header {egress}, DMA the
    frame, wait for the H2C completed-count != 0 (it resets to 0 on RUN).
    **`dma_slow_path_rx`** (C2H, punt): a **continuously-running CIRCULAR
    descriptor ring** (never stop/re-armed per frame — that wedges the engine),
    reaped by a consumer index vs the completed count (each frame once, no loss/
    dup). Length from the in-band header's `byte_len` (SAF-measured in the FPGA;
    §9), with the L2/L3 parse (`punt_frame_len`) kept as a fallback for `byte_len==0`.
    In-band header carries {lif_id, ingress, byte_len}.
  - `bar_slow_path_rx/tx` branch to the DMA path when `c->dma` is set — so
    `pw_host_plane_step` and the backend-ops signatures are **unchanged**. The
    daemon worker poll cap is 1 ms (C2H has no fd to wake `poll`).

### HW bring-up — DONE (2026-07-04, flashed 07:00.0 build_id 0x6a47e2bc)

Flashed + booted; **full cRPD 2-node control plane validated across the DUT via
the DMA slow path: ARP, ICMP ping (0 % loss, ~2.2 ms RTT), BGP Established, OSPF
Full, IS-IS L1+L2 Up** (R1/R2 learn each other's loopback via OSPF *and* IS-IS).
Silicon corrected several design assumptions; the as-built code reflects these:

1. **BAR layout: NOT a 128 KB split BAR0.** The IP exposes TWO 64 KB BARs —
   **BAR0 = AXI-Lite CSR at offset 0 (UNCHANGED; the CSR did NOT move)**, **BAR1 =
   XDMA control registers**. So `csr_off = 0`; the backend maps BAR0 for CSR +
   BAR1 (via `pw_vfio_map_region`) for the XDMA engine. (`PWFPGA_CSR_DMA_OFFSET`
   is kept only as a probe fallback for a hypothetical future single-big-BAR.)
   → review #2's "+0x10000 breaks the daemon" concern was moot.
2. **IOMMU `VFIO_IOMMU_MAP_DMA` works** (no Secure-Boot/lockdown block on
   bus-master DMA); H2C inject validated end-to-end (frames egress + loop).
3. **Completed-count RESETS to 0 on RUN** (single-descriptor mode). For H2C
   inject, wait for the count `!= 0` — reading a baseline races either way (before
   RUN latches the stale 1 from the previous inject → immediate false completion,
   dropped inject; after RUN a descriptor completing before the read latches
   base=1 → spins to timeout). The **C2H uses a continuously-running CIRCULAR
   descriptor ring** (never stop/re-armed per frame — a per-frame stop→run wedges
   the engine) with a consumer index; each frame is delivered exactly once, no
   unarmed gap.
4. **C2H received length is NOT in `desc.bytes`** (it stays = the programmed
   capacity). The RTL now carries the frame length in a **`byte_len` field of the
   in-band header** (§9): the punt SAF in `pw_dma_slowpath` counts the frame's
   bytes in the dp domain and writes them at header bytes 5-6 (LE) ahead of the
   frame. The host reads that directly. The old L2/L3 parse (`punt_frame_len`:
   ARP=42, IPv4=eth+IP-total-len, IPv6=eth+40+payload, IS-IS/LLC=eth+802.3-len) is
   kept only as a fallback for `byte_len==0`. This generalises punt to arbitrary
   ethertypes/VLAN/QinQ. **DONE + HW-validated 2026-07-04 (build 0x6a48854f)** —
   the debug log read `len=8062` straight from the header on a jumbo frame.
5. **Punt-reap cadence:** the daemon worker poll cap was cut 100 ms → 1 ms (C2H
   has no fd to wake `poll`; 100 ms let punt replies sit a poll period → cRPD
   retransmit storms → seconds of RTT + no adjacency).
6. **DMA-pool layout must not overlap** — the TX buffer has to sit after the whole
   C2H ring (an off-by-descriptors overlap corrupted ring entries 14/15).
7. **cRPD interface reference:** OSPF/IS-IS use `interface net0` (device), NOT
   `net0.0`; the `.0` unit form silently never attached. `packetwyrmd` also marks
   the TAP tun carrier UP (TUNSETCARRIER). See the lab README.

### Jumbo (MTU 9000) — DONE + HW-validated (2026-07-04, build_id 0x6a481d26)

Four data-path frame-size caps had to be raised together; each was found by a
graduated ping (1600 B OK / 2000 B drop pinned each successive ~2 KB limiter):
1. **MAC BASE-R PCS** `cfg_tx/rx_max_pkt_len` 1518 → 9600 (pw_sfp_10g).
2. **MAC↔dp_clk CDC FIFO** DEPTH 2048 → 16384 B (board).
3. **Data-plane forward/punt SAF** `SAF_DEPTH_BEATS` 512 → 2048 (16 KB; threaded
   param, set at the board).
4. **pw_dma_slowpath async-FIFO** FIFO_DEPTH 2048 → 16384 B (the taxi DEPTH is in
   BYTES, not "words×8" — this was the last, subtlest cap).
5. **Host** `PW_HOST_FRAME_MAX` 2048 → 9600 B (daemon punt/inject buffer).
6. **Host DMA buffer** `PW_DMA_FRAME_CAP` 9216 → 16384 B (the C2H/H2C descriptor
   buffers). The MAC accepts up to 9599 B and the punt SAF buffers up to
   PSAF_BEATS×8 = 10240 B, so a punt of `{≤9599 B frame + 8 B header}` must fit
   the C2H buffer; the old 9216 left frames in 9209..9599 B liable to C2H
   truncation (fixed to match the RTL async-FIFO DEPTH, host-side only — no
   reflash; the MTU-9000 traffic already validated on HW is ≤~9018 B, so this is
   a hardening of the configured-max edge, not a regression of the tested path).

Validated on 07:00.0 at MTU 9000: v4 pings 2000/4000/6000/8000/8900 B and a v6
8000 B ping all 0 % loss; the full dual-stack control plane (OSPFv2/OSPFv3 Full,
IS-IS L1+L2 Up, BGP v4+v6 Established) stays up. Gated build WNS +0.084 (all
clocks), LUT 94.79 %, BRAM 53 %.

Follow-up: **DONE (2026-07-04, build 0x6a48854f)** — the punt in-band header now
carries a `byte_len` field (SAF-measured in the FPGA; §9), so punt length no
longer depends on the L2/L3 parse and generalises to VLAN/QinQ/unknown-ethertype.
The L2/L3 recovery is retained only as a `byte_len==0` fallback.

## 6. Phasing — **P1–P5 COMPLETE incl. jumbo (2026-07-04)**

P1 (RTL+sim), P2 (host DMA driver), P3 (integrate under `pw_host_plane`),
P4 (gated build + flash 07:00.0 + HW bring-up), and P5 (cRPD lab: dual-stack
ARP/ND/ping/BGP/BGP-v6/OSPFv2/OSPFv3/IS-IS all Up across the DUT, **incl. MTU
9000 jumbo**) are all done. The original phase descriptions follow for reference:

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

1. **Approach: A2** (XDMA AXI-Stream). A1's "no-regen" premise was false (the MM
   data mover was tied off, so an AXI-Stream regen is needed either way); A2's
   leaner RTL wins. B held in reserve. No control-BAR enable key is required — the
   DMA/SGDMA registers are in BAR0 (§5a-bis); enabling the DMA engine relocates
   the AXI-Lite CSR to BAR0 offset `0x10000` (a P2 host-side gate).
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

**As-built header (8 B, one 64-b beat), settled in P1 + extended 2026-07-04:**

| bytes | field       | direction | notes                                            |
|-------|-------------|-----------|--------------------------------------------------|
| 0-3   | `lif_id`    | punt      | logical-IF id, little-endian                     |
| 4     | `ingress`   | punt      | ingress port (low nibble)                        |
| 5-6   | `byte_len`  | punt      | frame length in bytes, LE — **SAF-measured** in the dp domain by `pw_dma_slowpath` (see below) |
| 7     | rsv         | —         | 0                                                |
| 0     | `egress`    | inject    | egress port; engine strips the header before TX  |

On punt the engine can't know the frame length until `tlast`, so
`pw_dma_slowpath` runs a small dp-domain **store-and-forward** (PS_FILL → PS_HDR →
PS_DRAIN): it buffers one frame in BRAM counting bytes, emits the header beat with
the measured `byte_len`, then drains the frame into the async FIFO. The host
prefers `byte_len`; a zero falls back to the L2/L3 parse (`punt_frame_len`).
