// Fixed-value version package for simulation. The real
// `pw_version_pkg.sv` is generated at Vivado build time; sim and
// lint substitute this stable copy.

`ifndef PW_VERSION_PKG_SV
`define PW_VERSION_PKG_SV

package pw_version_pkg;
    localparam logic [31:0] PW_VERSION  = 32'h00010000;
    localparam logic [31:0] PW_BUILD_ID = 32'hFACE0000;
    localparam logic [31:0] PW_GIT_HASH = 32'hDEADBEEF;
endpackage : pw_version_pkg

`endif
