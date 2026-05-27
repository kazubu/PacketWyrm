# RTL simulation

Targets and required cases are listed in `docs/test-plan.md`. The
recommended stack is **cocotb + Verilator** for fast Python-driven
tests, with optional Vivado simulation for Xilinx-IP-heavy modules.

Phase 2+ populates this directory with:

- `parser_tb/` &mdash; per-protocol header extraction
- `classifier_tb/` &mdash; priority + shadow / commit
- `flow_gen_tb/` &mdash; rate-limit / IFG correctness
- `test_rx_checker_tb/` &mdash; loss / dup / reorder / latency
- `csr_fabric_tb/` &mdash; W1C, snapshot atomicity
- `histogram_tb/` &mdash; bin boundary correctness
- `slow_path_dma_tb/` &mdash; descriptor / completion ordering

`make sim` should orchestrate these once the first testbench lands.
