#!/usr/bin/env bash
# Regenerate src/pcie_gen3_stub.sv (the lint / use_ip=0 placeholder for
# the generated xdma wrapper) from the IP's synthesis blackbox stub.
# Run this after changing ip/pcie_gen3.tcl and re-running `make ip`, so
# the stub's port list keeps matching the real IP and Verilator lint
# stays meaningful.
#
#   ./ip/gen_stub.sh
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
stub=$(find "$here/build" -name 'pcie_gen3_wrapper_stub.v' 2>/dev/null | head -1)
if [ -z "$stub" ]; then
    echo "no generated pcie_gen3_wrapper_stub.v found; run 'make ip' first" >&2
    exit 1
fi
python3 - "$stub" > "$here/src/pcie_gen3_stub.sv" <<'PY'
import sys, re
txt = open(sys.argv[1]).read()
txt = re.sub(r'\(\*.*?\*\)', '', txt, flags=re.S)
txt = re.sub(r'/\*.*?\*/', '', txt, flags=re.S)
ports = []
for m in re.finditer(r'\b(input|output)\b\s*(\[[0-9]+\s*:\s*[0-9]+\])?\s*([A-Za-z_][A-Za-z0-9_]*)\s*;', txt):
    d, w, n = m.group(1), (m.group(2) or '').replace(' ',''), m.group(3)
    ports.append((d, w, n))
outs = [p for p in ports if p[0]=='output']
ins  = [p for p in ports if p[0]=='input']
W = max(len(w) for _,w,_ in ports)
L = []
L += ["// Phase 1 lint/no-IP placeholder for the generated xdma wrapper",
      "// (DMA mode + AXI-Lite master). AUTO-GENERATED from the IP's",
      "// pcie_gen3_wrapper_stub.v by ip/gen_stub.sh -- do not hand-edit;",
      "// regenerate after changing the IP config. Used only for Verilator",
      "// lint and the use_ip=0 LED/timing smoke build; the real IP wrapper",
      "// replaces it when use_ip=1.","",
      "`default_nettype none","","module pcie_gen3_wrapper ("]
for i,(d,w,n) in enumerate(ports):
    L.append(f"    {d:<6} wire {w:<{W}} {n}" + ("" if i==len(ports)-1 else ","))
L += [");","",
      "    // Quiet defaults: never drive the line, never master a transaction.",
      "    assign axi_aclk    = sys_clk;",
      "    assign axi_aresetn = sys_rst_n;",
      "    assign user_lnk_up = 1'b0;"]
for d,w,n in outs:
    if n in ('axi_aclk','axi_aresetn','user_lnk_up'): continue
    L.append(f"    assign {n} = '0;")
L += ["", "    wire _unused = &{1'b0, " + ", ".join(n for _,_,n in ins) + ", 1'b0};",
      "", "endmodule", "", "`default_nettype wire"]
print("\n".join(L))
PY
echo "regenerated src/pcie_gen3_stub.sv"
