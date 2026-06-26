// Gray-coded timestamp clock-domain crossing.
//
// The free-running latency timestamp is generated on dp_clk. Egress
// hardware timestamping (pw_ts_insert) needs that same time base in the
// MAC TX clock domain. Gray-coding makes the multi-bit counter safe to
// sample across the (plesiochronous, ~156.25 MHz both) domains: only one
// bit changes per increment, so a sample taken mid-transition resolves to
// N or N+1 -- never a far-off value -- which keeps min/max latency clean.
//
// 1-2 dst-clock latency; consistent, so it just adds a fixed offset.

`default_nettype none

module pw_ts_gray_cdc #(
    parameter int W = 64
) (
    input  wire         src_clk,
    input  wire [W-1:0] src_bin,    // free-running counter (dp_clk)
    input  wire         dst_clk,
    output logic [W-1:0] dst_bin    // same value, dst_clk domain
);
    function automatic logic [W-1:0] bin2gray(input logic [W-1:0] b);
        return b ^ (b >> 1);
    endfunction
    function automatic logic [W-1:0] gray2bin(input logic [W-1:0] g);
        logic [W-1:0] b;
        b[W-1] = g[W-1];
        for (int i = W-2; i >= 0; i--) b[i] = b[i+1] ^ g[i];
        return b;
    endfunction

    // Source: register the Gray code (src_clk domain -- NOT a synchronizer FF,
    // so no ASYNC_REG; the gray_src -> sync1 crossing is constrained by
    // set_max_delay -datapath_only + set_bus_skew in xdc/phase3_cdc.xdc).
    logic [W-1:0] gray_src;
    always_ff @(posedge src_clk) gray_src <= bin2gray(src_bin);

    // Destination: 2-FF synchronizer (ASYNC_REG -> placed together for MTBF),
    // then convert back to binary.
    (* ASYNC_REG = "TRUE" *) logic [W-1:0] sync1, sync2;
    always_ff @(posedge dst_clk) begin
        sync1 <= gray_src;
        sync2 <= sync1;
    end
    always_ff @(posedge dst_clk) dst_bin <= gray2bin(sync2);

endmodule

`default_nettype wire
