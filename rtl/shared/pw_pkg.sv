// PacketWyrm shared package: board-agnostic constants used by the
// minimum CSR fabric and the upcoming full data-plane RTL.

`ifndef PW_PKG_SV
`define PW_PKG_SV

package pw_pkg;

    // Vendor / device id reported in BAR0 register 0x0000.
    // The numeric value is symbolic for Phase 1; matched by
    // packetwyrmd's pci discovery. AS02MC04-specific PCIe vendor /
    // device IDs are configured on the PCIe Gen3 IP separately and
    // are programmed via the AS02MC04 board's PCIe wrapper.
    localparam logic [31:0] PW_DEVICE_ID = 32'hA502BEEF;

    // Capabilities bitmap exposed at BAR0 register 0x0010.
    // See docs/design/csr-map.md.
    localparam logic [31:0] PW_CAP_HAS_DMA            = 32'h0000_0001;
    localparam logic [31:0] PW_CAP_HAS_MSIX           = 32'h0000_0002;
    localparam logic [31:0] PW_CAP_HAS_HISTOGRAM      = 32'h0000_0004;
    localparam logic [31:0] PW_CAP_HAS_QINQ_PARSER    = 32'h0000_0008;
    localparam logic [31:0] PW_CAP_HAS_TIMESTAMP_SYNC = 32'h0000_0010;
    localparam logic [31:0] PW_CAP_HAS_MIRROR         = 32'h0000_0020;

    // Phase 1 advertises no optional features. Each phase OR's its
    // contribution into PW_CAPABILITIES via a build-time override.
    localparam logic [31:0] PW_PHASE1_CAPABILITIES = 32'h0000_0000;

    // BAR0 register offsets (see docs/design/csr-map.md).
    localparam logic [11:0] PW_REG_DEVICE_ID      = 12'h000;
    localparam logic [11:0] PW_REG_VERSION        = 12'h004;
    localparam logic [11:0] PW_REG_BUILD_ID       = 12'h008;
    localparam logic [11:0] PW_REG_GIT_HASH       = 12'h00c;
    localparam logic [11:0] PW_REG_CAPABILITIES   = 12'h010;
    localparam logic [11:0] PW_REG_NUM_PORTS      = 12'h014;
    localparam logic [11:0] PW_REG_NUM_FLOWS      = 12'h018;
    localparam logic [11:0] PW_REG_NUM_LOG_IFS    = 12'h01c;
    localparam logic [11:0] PW_REG_NUM_CLS        = 12'h020;
    localparam logic [11:0] PW_REG_NUM_HIST_BINS  = 12'h024;

    localparam logic [11:0] PW_REG_GLOBAL_CONTROL = 12'h100;
    localparam logic [11:0] PW_REG_GLOBAL_STATUS  = 12'h104;
    localparam logic [11:0] PW_REG_TIMESTAMP_LOW  = 12'h108;
    localparam logic [11:0] PW_REG_TIMESTAMP_HIGH = 12'h10c;
    localparam logic [11:0] PW_REG_ERROR_STATUS   = 12'h110;

    // Number of physical ports per AS02MC04 (two SFP+ cages).
    localparam int PW_NUM_LOCAL_PORTS = 2;

endpackage : pw_pkg

`endif
