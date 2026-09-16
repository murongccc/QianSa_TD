`timescale 1ns/1ps

module tb_source_pixel_fifo_ip;
    reg clk = 1'b0;
    reg srst = 1'b1;
    reg we = 1'b0;
    reg re = 1'b0;
    reg [31:0] di = 32'd0;
    wire [31:0] dout;
    wire empty_flag, full_flag, valid, afull, aempty;
    wire overflow, underflow, wr_success, wr_rst_done, rd_rst_done;
    wire [9:0] rdusedw, wrusedw;

    always #5 clk = ~clk;

    source_pixel_fifo_ip dut(
        .srst(srst), .di(di), .clk(clk), .re(re), .we(we), .dout(dout),
        .empty_flag(empty_flag), .aempty(aempty), .full_flag(full_flag),
        .afull(afull), .valid(valid), .overflow(overflow),
        .underflow(underflow), .wr_success(wr_success),
        .rdusedw(rdusedw), .wrusedw(wrusedw),
        .wr_rst_done(wr_rst_done), .rd_rst_done(rd_rst_done)
    );

    initial begin
        repeat (4) @(negedge clk);
        srst = 1'b0;
        repeat (4) @(negedge clk);
        if (!empty_flag || valid)
            $fatal(1, "FIFO not empty after reset: empty=%b valid=%b", empty_flag, valid);

        di = 32'h11223344;
        we = 1'b1;
        @(negedge clk);
        we = 1'b0;
        repeat (2) @(negedge clk);
        if (empty_flag || !valid || dout !== 32'h11223344)
            $fatal(1, "show-ahead mismatch: empty=%b valid=%b dout=%h", empty_flag, valid, dout);

        re = 1'b1;
        @(negedge clk);
        re = 1'b0;
        repeat (2) @(negedge clk);
        if (!empty_flag || valid)
            $fatal(1, "FIFO did not retire word: empty=%b valid=%b", empty_flag, valid);

        $display("PASS source_pixel_fifo_ip: synchronous reset and show-ahead valid semantics");
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "source FIFO timeout");
    end
endmodule
