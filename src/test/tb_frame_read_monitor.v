`timescale 1ns/1ps

module tb_frame_read_monitor;
localparam FRAME_PIXELS = 4;

reg clk = 1'b0;
reg rst = 1'b1;
reg display_valid_async = 1'b0;
reg [1:0] display_slot_async = 2'd0;
reg vs = 1'b0;
reg fifo_read_req = 1'b0;
reg fifo_empty = 1'b0;
reg fifo_valid = 1'b0;
reg [31:0] fifo_data = 32'd0;
wire [15:0] underflow_count;
wire underflow_sticky;
wire [15:0] mismatch_count;
wire mismatch_sticky;

always #5 clk = ~clk;

frame_read_monitor #(.FRAME_PIXELS(FRAME_PIXELS)) dut (
    .clk(clk), .rst(rst), .display_valid_async(display_valid_async),
    .display_slot_async(display_slot_async), .vs(vs),
    .fifo_read_req(fifo_read_req), .fifo_empty(fifo_empty),
    .fifo_valid(fifo_valid), .fifo_data(fifo_data),
    .underflow_count(underflow_count), .underflow_sticky(underflow_sticky),
    .mismatch_count(mismatch_count), .mismatch_sticky(mismatch_sticky)
);

task frame_start;
    begin
        @(negedge clk); vs = 1'b1;
        @(posedge clk); #1;
        @(negedge clk); vs = 1'b0;
    end
endtask

task pixel;
    input [31:0] value;
    begin
        @(negedge clk); fifo_data = value; fifo_valid = 1'b1;
        @(posedge clk); #1;
        @(negedge clk); fifo_valid = 1'b0;
    end
endtask

task complete_frame;
    input [31:0] changed_value;
    input        use_change;
    begin
        pixel(32'h01020304);
        pixel(32'h11121314);
        pixel(use_change ? changed_value : 32'h21222324);
        pixel(32'h31323334);
        frame_start;
    end
endtask

initial begin
    repeat (3) @(posedge clk);
    rst = 1'b0;
    display_valid_async = 1'b1;
    repeat (3) @(posedge clk);

    // 第一个完整帧只建立槽0基线，第二个相同帧不得误报。
    frame_start;
    complete_frame(32'd0, 1'b0);
    complete_frame(32'd0, 1'b0);
    if (mismatch_count != 16'd0)
        $fatal(1, "identical frames raised a mismatch");

    // 单像素变化必须产生一次帧数据变化。
    complete_frame(32'hdeadbeef, 1'b1);
    if (mismatch_count != 16'd1 || !mismatch_sticky)
        $fatal(1, "changed pixel was not detected");

    // 缺失像素和额外像素各产生一次计数。
    pixel(32'h01020304); pixel(32'h11121314); pixel(32'h21222324); frame_start;
    if (mismatch_count != 16'd2)
        $fatal(1, "missing pixel was not detected");
    pixel(32'h01020304); pixel(32'h11121314); pixel(32'h21222324);
    pixel(32'h31323334); pixel(32'h41424344); frame_start;
    if (mismatch_count != 16'd3)
        $fatal(1, "extra pixel was not detected");

    // 槽1首帧建立独立基线；切回槽0后继续使用原基线。
    display_slot_async = 2'd1; repeat (3) @(posedge clk);
    // 当前帧仍属于槽0；边界后下一帧才属于槽1。
    complete_frame(32'd0, 1'b0);
    complete_frame(32'd0, 1'b0);
    if (mismatch_count != 16'd3)
        $fatal(1, "new slot baseline raised a mismatch");
    display_slot_async = 2'd0; repeat (3) @(posedge clk);
    complete_frame(32'd0, 1'b0);
    complete_frame(32'd0, 1'b0);
    if (mismatch_count != 16'd3)
        $fatal(1, "return to slot0 did not reuse its baseline");

    // 正常请求不报空读；连续空读分别计数并保持粘滞。
    @(negedge clk); fifo_read_req = 1'b1; fifo_empty = 1'b0;
    @(posedge clk); #1;
    @(negedge clk); fifo_empty = 1'b1;
    repeat (3) @(posedge clk);
    #1;
    if (underflow_count != 16'd3 || !underflow_sticky)
        $fatal(1, "FIFO underflow events were not counted");

    // 持续空读必须在 0xffff 饱和，不能回卷并丢失故障证据。
    repeat (65534) @(posedge clk);
    #1;
    if (underflow_count != 16'hffff || !underflow_sticky)
        $fatal(1, "FIFO underflow counter did not saturate");

    $display("PASS frame read monitor: underflow and per-slot frame signatures");
    $finish;
end

initial begin
    #1000000;
    $fatal(1, "frame read monitor timeout");
end
endmodule
