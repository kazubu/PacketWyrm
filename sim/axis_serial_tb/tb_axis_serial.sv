// Round-trip test for the wide<->64-bit AXIS converter pair.
//
// Builds a small frame, drives it through pw_axis_serializer, loops
// the resulting AXIS beats into pw_axis_deserializer, and checks
// that the reconstructed pw_frame_t is byte-for-byte identical to
// the original.
//
// Additionally checks the on-the-wire lane convention DIRECTLY (a
// round-trip alone would pass under any self-consistent packing):
// wire byte k must ride in tdata[k*8 +: 8] qualified by tkeep[k]
// (the production convention, cf. pw_flow_gen_multi / pw_ts_insert),
// and tkeep on a partial last beat must qualify the LOW lanes that
// actually hold data.

`default_nettype none

import pw_axis_pkg::*;

module tb_axis_serial;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst_n = 1'b0;

    /* ---- TX (wide -> AXIS) ---- */
    pw_frame_t  tx_frame;
    logic       tx_valid;
    logic       tx_ready;

    logic [63:0] axis_tdata;
    logic [7:0]  axis_tkeep;
    logic        axis_tvalid;
    logic        axis_tready;
    logic        axis_tlast;

    pw_axis_serializer u_ser (
        .clk           (clk),
        .rst_n         (rst_n),
        .frame_i       (tx_frame),
        .frame_valid_i (tx_valid),
        .frame_ready_o (tx_ready),
        .m_tdata       (axis_tdata),
        .m_tkeep       (axis_tkeep),
        .m_tvalid      (axis_tvalid),
        .m_tready      (axis_tready),
        .m_tlast       (axis_tlast)
    );

    /* ---- RX (AXIS -> wide) ---- */
    pw_frame_t   rx_frame;
    logic        rx_valid;

    pw_axis_deserializer u_des (
        .clk             (clk),
        .rst_n           (rst_n),
        .s_tdata         (axis_tdata),
        .s_tkeep         (axis_tkeep),
        .s_tvalid        (axis_tvalid),
        .s_tready        (axis_tready),
        .s_tlast         (axis_tlast),
        .frame_o         (rx_frame),
        .frame_valid_o   (rx_valid),
        .ingress_port_i  (4'h3)
    );

    int errors = 0;

    // Beat monitor: extract wire bytes from the AXIS bus using the
    // production lane convention (byte k = tdata[k*8 +: 8], gated by
    // tkeep[k]); also require tkeep to be contiguous from lane 0.
    logic [7:0] wire_bytes [$];
    always @(posedge clk) begin
        if (axis_tvalid && axis_tready) begin
            logic seen_gap = 1'b0;
            for (int k = 0; k < 8; k++) begin
                if (axis_tkeep[k]) begin
                    if (seen_gap) begin
                        $display("[FAIL] tkeep not contiguous from lane 0: %b",
                                 axis_tkeep);
                        errors++;
                    end
                    wire_bytes.push_back(axis_tdata[k*8 +: 8]);
                end else begin
                    seen_gap = 1'b1;
                end
            end
        end
    end

    task automatic check_eq(string what, longint got, longint exp);
        if (got != exp) begin
            $display("[FAIL %s] got=%0d exp=%0d", what, got, exp);
            errors++;
        end else begin
            $display("[ ok %s] %0d", what, got);
        end
    endtask

    /* Construct a deterministic test frame: header + counted body. */
    function automatic pw_frame_t make_payload(input int len);
        pw_frame_t f;
        f = pw_frame_zero();
        // Ethernet-ish header (10 bytes of dst+src+etype)
        f.data[0] = 8'h02; f.data[1]  = 8'ha5; f.data[2]  = 8'h02;
        f.data[3] = 8'h00; f.data[4]  = 8'h00; f.data[5]  = 8'h02;
        f.data[6] = 8'hde; f.data[7]  = 8'had; f.data[8]  = 8'hbe;
        f.data[9] = 8'hef; f.data[10] = 8'h08; f.data[11] = 8'h00;
        // Body: byte i = i & 0xff
        for (int i = 12; i < len; i++) f.data[i] = i[7:0];
        f.len = PW_FRAME_LEN_W'(len);
        return f;
    endfunction

    /* ---- drive scenarios ---- */
    int        lens [4] = '{ 14, 16, 60, 100 };
    int        target_len, timeout, mismatch;
    pw_frame_t exp_frame;

    initial begin
        tx_frame = pw_frame_zero();
        tx_valid = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        for (int idx = 0; idx < 4; idx++) begin
            target_len = lens[idx];
            exp_frame  = make_payload(target_len);
            wire_bytes = {};

            // submit
            tx_frame = exp_frame;
            tx_valid = 1'b1;
            @(posedge clk);
            tx_valid = 1'b0;

            // wait for the deserializer to report a complete
            // frame; safety-cap to avoid runaway sims.
            timeout = 0;
            while (!rx_valid && timeout < 200) begin
                @(posedge clk);
                timeout++;
            end

            check_eq($sformatf("len=%0d frame complete", target_len),
                     rx_valid ? 1 : 0, 1);
            check_eq($sformatf("len=%0d rx.len", target_len),
                     rx_frame.len, target_len);
            check_eq($sformatf("len=%0d rx.ingress_port", target_len),
                     rx_frame.ingress_port, 3);

            // compare body byte by byte
            mismatch = 0;
            for (int j = 0; j < target_len; j++) begin
                if (rx_frame.data[j] !== exp_frame.data[j]) mismatch++;
            end
            check_eq($sformatf("len=%0d body match (mismatch count)",
                               target_len),
                     mismatch, 0);

            // direct lane-convention check: the bytes seen on the AXIS
            // bus (via tdata[k*8 +: 8] / tkeep[k]) must be the wire
            // bytes, in order.
            check_eq($sformatf("len=%0d wire byte count", target_len),
                     wire_bytes.size(), target_len);
            mismatch = 0;
            for (int j = 0; j < target_len && j < wire_bytes.size(); j++) begin
                if (wire_bytes[j] !== exp_frame.data[j]) mismatch++;
            end
            check_eq($sformatf("len=%0d wire lane convention (mismatch count)",
                               target_len),
                     mismatch, 0);
            @(posedge clk);   // let rx_valid drop
        end

        if (errors == 0) begin
            $display("ALL AXIS_SERIAL SCENARIOS PASS");
            $finish;
        end else begin
            $display("FAILED with %0d error(s)", errors);
            $fatal;
        end
    end

    initial begin
        #100000;
        $display("WATCHDOG TIMEOUT");
        $fatal;
    end

endmodule

`default_nettype wire
