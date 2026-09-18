`timescale 1ns/1ps

module tb_frame_read_fifo_diag;
reg mem_clk = 1'b0;
reg video_clk = 1'b0;
reg rst = 1'b1;
reg we = 1'b0;
reg re = 1'b0;
reg [31:0] din = 32'd0;
reg display_valid = 1'b0;
reg vs = 1'b0;
wire [31:0] dout;
wire fifo_valid, fifo_empty;
wire [8:0] fifo_level;
wire [15:0] underflow_count, mismatch_count;
wire underflow_sticky, mismatch_sticky;
integer valid_seen = 0;

always #4 mem_clk = ~mem_clk;
always #10 video_clk = ~video_clk;
always @(posedge video_clk)
    if (fifo_valid)
        valid_seen = valid_seen + 1;

rfifo_32_32_512 fifo_dut (
    .rst(rst), .clkw(mem_clk), .clkr(video_clk),
    .we(we), .di(din), .re(re), .dout(dout), .valid(fifo_valid),
    .full_flag(), .empty_flag(fifo_empty), .afull(), .aempty(),
    .wrusedw(), .rdusedw(fifo_level)
);

frame_read_monitor #(.FRAME_PIXELS(4)) monitor_dut (
    .clk(video_clk), .rst(rst), .display_valid_async(display_valid),
    .display_slot_async(2'd0), .vs(vs),
    .fifo_read_req(re), .fifo_empty(fifo_empty),
    .fifo_valid(fifo_valid), .fifo_data(dout),
    .underflow_count(underflow_count), .underflow_sticky(underflow_sticky),
    .mismatch_count(mismatch_count), .mismatch_sticky(mismatch_sticky)
);

task write_word;
    input [31:0] value;
    begin
        @(negedge mem_clk); din = value; we = 1'b1;
        @(posedge mem_clk);
        @(negedge mem_clk); we = 1'b0;
    end
endtask

initial begin
    repeat (4) @(posedge mem_clk);
    rst = 1'b0;
    display_valid = 1'b1;
    repeat (4) @(posedge video_clk);

    write_word(32'h11111111);
    write_word(32'h22222222);
    write_word(32'h33333333);
    write_word(32'h44444444);
    wait (!fifo_empty);

    @(negedge video_clk); re = 1'b1;
    repeat (4) @(posedge video_clk);
    @(negedge video_clk); re = 1'b0;
    repeat (3) @(posedge video_clk);
    if (valid_seen != 4)
        $fatal(1, "FIFO valid timing lost data: valid_seen=%0d", valid_seen);
    if (underflow_count != 16'd0)
        $fatal(1, "normal FIFO reads raised underflow");

    wait (fifo_empty);
    @(negedge video_clk); re = 1'b1;
    repeat (3) @(posedge video_clk);
    @(negedge video_clk); re = 1'b0;
    #1;
    if (underflow_count != 16'd3 || !underflow_sticky)
        $fatal(1, "starved SDRAM return did not raise FIFO underflow");

    $display("PASS frame read FIFO diagnostics: valid timing and starvation detection");
    $finish;
end

initial begin
    #20000;
    $fatal(1, "frame read FIFO diagnostic timeout");
end
endmodule
