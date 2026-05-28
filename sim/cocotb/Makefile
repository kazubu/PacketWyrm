# PacketWyrm cocotb / Python testbench (TODO #5)
#
# Reuses Scapy to construct realistic frames and feeds them into
# behavioural reference RTL (sim/cocotb/rtl/) for the parser,
# classifier, and flow generator. The cocotb tests live alongside
# the SystemVerilog testbenches in sim/, but use Icarus Verilog
# (the Verilator in this environment is older than cocotb's VPI
# minimum). They complement, not replace, the SV testbenches:
#
#   - sim_all (Verilator)  : integration coverage on the real RTL
#   - cocotb  (Icarus)     : Scapy-driven, Python-asserted unit tests
#
# Targets:
#   make sim_parser       parser unit tests
#   make sim_classifier   classifier unit tests
#   make sim_flow_gen     flow generator unit tests
#   make all              all three
#   make clean

PYTHON   ?= python3
RTL_DIR  := rtl

.PHONY: all clean sim_parser sim_classifier sim_flow_gen

all: sim_parser sim_classifier sim_flow_gen

sim_parser:
	$(PYTHON) run_tests.py parser

sim_classifier:
	$(PYTHON) run_tests.py classifier

sim_flow_gen:
	$(PYTHON) run_tests.py flow_gen

clean:
	rm -rf sim_build_* __pycache__ tests/__pycache__ results.xml
