# AS02MC04 board-support project

This directory will hold the Vivado project, pin / clocking / timing
constraints, and board-support RTL wrappers specific to the Alibaba
Cloud AS02MC04 card (Kintex UltraScale+ KU3P, two SFP+ cages, PCIe
Gen3).

Phase 1 deliverables:

- `project.tcl` &mdash; reproducible Vivado project creation
- `xdc/timing.xdc`, `xdc/pinout.xdc`, `xdc/physical.xdc`
- `ip/` &mdash; Xilinx IP wrappers (GTY, PCIe Gen3, 10GBASE-R MAC+PCS)
- `src/` &mdash; clocking, reset, LED heartbeat, sysmon
- `bd/` &mdash; (optional) block design

Board-agnostic RTL (parser, classifier, flow generator, test checker,
CSR fabric) lives in `../../rtl/` and is referenced from the project
script. Future 25G or alternate boards reuse that shared RTL.

See `docs/design/rtl-modules.md` and `docs/phases/poc-phase-1-3.md`.
