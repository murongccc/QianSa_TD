`timescale 1ns/1ps

// Self-checks the OSD pixel priority using a compact 64x480 timing model.
// The subtitle coordinates retain their production y positions, while the
// smaller width makes the test quick and sufficient for the overlay logic.
module tb_video_presentation;
reg clk = 1'b0;
reg rst = 1'b1;
reg display_valid = 1'b1;
reg [1:0] display_slot_async = 2'd0;
reg [2:0] brightness_level_async = 3'd4;
reg [2:0] volume_level_async = 3'd4;
reg de = 1'b0;
reg vs = 1'b0;
reg [23:0] rgb_in = 24'h808080;
wire [23:0] rgb_out;
integer line;
integer pixel;

always #20 clk = ~clk;

video_presentation #(
    .ACTIVE_WIDTH(64), .ACTIVE_HEIGHT(480)
) dut (
    .clk(clk), .rst(rst), .display_valid(display_valid),
    .display_slot_async(display_slot_async),
    .brightness_level_async(brightness_level_async),
    .volume_level_async(volume_level_async), .de(de), .vs(vs),
    .rgb_in(rgb_in), .rgb_out(rgb_out)
);

task next_frame;
    begin
        @(negedge clk); vs = 1'b1;
        @(negedge clk); vs = 1'b0;
    end
endtask

task active_line;
    input integer y;
    begin
        @(negedge clk); de = 1'b1;
        for (pixel = 0; pixel < 64; pixel = pixel + 1) begin
            @(posedge clk);
            if (y == 438 && pixel == 2 && rgb_out != 24'hFFE040)
                $fatal(1, "subtitle glyph did not have highest priority");
            if (y == 430 && pixel == 32 && rgb_out == rgb_in)
                $fatal(1, "subtitle banner did not alpha blend the background");
        end
        @(negedge clk); de = 1'b0;
    end
endtask

initial begin
    repeat (3) @(posedge clk);
    rst = 1'b0;
    next_frame;
    for (line = 0; line < 480; line = line + 1)
        active_line(line);
    if (dut.subtitle_scroll_x != 9'd0)
        $fatal(1, "subtitle moved before its configured tick period");
    $display("PASS: subtitle text and alpha banner overlay priorities");
    $finish;
end
endmodule
