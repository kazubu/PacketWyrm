# cocotb / Python testbench (TODO #5)

Scapy-driven, Python-asserted unit tests for the Phase 3 data-plane
sub-modules. Lives alongside the SystemVerilog testbenches in `sim/`
but uses a different simulator and a separate set of small,
Icarus-compatible behavioural RTL files under `rtl/`.

## Why a parallel RTL tree

cocotb 2.x requires Verilator ≥ 5.036; the Verilator shipped here
is 5.020, so the cocotb suite runs under Icarus Verilog instead.
Icarus does not yet support a handful of constructs the production
RTL uses (`automatic` declarations inside `always_ff`, packed
structs through ports, function-call bit-slicing). The behavioural
modules in `rtl/` mirror the spec of `rtl/phase3/pw_parser.sv`,
`pw_classifier.sv`, and `pw_flow_gen.sv` using Icarus-friendly
constructs and flat per-field ports.

The Verilator suite (`make -C sim sim_all`) is still the integration
gate against the production RTL. cocotb complements it with
Scapy-built frames and Python assertions at the unit level.

## Running

```sh
make -C sim/cocotb all           # parser + classifier + flow_gen
make -C sim/cocotb sim_parser    # parser only
make -C sim/cocotb sim_classifier
make -C sim/cocotb sim_flow_gen
```

## Layout

```
sim/cocotb/
├── Makefile
├── README.md
├── run_tests.py                     # cocotb_tools.runner entry point
├── rtl/                             # Icarus-compatible behavioural RTL
│   ├── pw_parser_beh.sv
│   ├── pw_classifier_beh.sv
│   └── pw_flow_gen_beh.sv
└── tests/                           # Python tests
    ├── _pktwyrm_helpers.py          # Scapy frame builders
    ├── test_parser.py
    ├── test_classifier.py
    └── test_flow_gen.py
```

## Requirements

- `iverilog` (Icarus Verilog 11+)
- `cocotb` 2.x (`pip install cocotb`)
- `scapy` (`pip install scapy`)
