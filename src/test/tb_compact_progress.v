`timescale 1ns/1ps
// 紧凑布局进度乘数5，覆盖高字、负时间、零长度及320像素限幅。
module tb_compact_progress;
parameter integer BLOCK_HUD=1;
reg clk=0,rst=1,vs=0;
always #20 clk=~clk;
reg signed [32:0] time_value=0;
reg [31:0] frames=0;
wire capture;
wire [8:0] progress=dut.progress;
rhythm_game_renderer #(.BLOCK_HUD(BLOCK_HUD),.BLOCK_GEOMETRY(1)) dut(
    .clk(clk),.rst(rst),.enabled(1'b1),.de(1'b0),.vs(vs),.song_time(time_value),.song_frames(frames),
    .state(4'd6),.error_code(4'd0),.auto_mode(1'b0),.score(20'd0),.combo(16'd0),.max_combo(16'd0),
    .perfect_count(16'd0),.good_count(16'd0),.bad_count(16'd0),.miss_count(16'd0),
    .metadata_valid(1'b0),.metadata_data(8'd0),.metadata_address(),.title(192'd0),.difficulty(128'd0),
    .view_index(),.view_valid(1'b0),.view_start(32'd0),.view_end(32'd0),.holding_mask(4'd0),
    .input_down(4'd0),.input_press(4'd0),.capture_busy(capture),.frame_enabled(),
    .pixel_on(),.pixel_light(),.pixel_rgb());
task check;
input signed [32:0] t;
input [31:0] f;
input [8:0] expected;
begin
    @(negedge clk);time_value=t;frames=f;vs=1;
    @(negedge clk);vs=0;repeat(4000)@(negedge clk);
    if(capture || progress!==expected)$fatal(1,"compact progress %d expected %d",progress,expected);
end endtask
initial begin
    repeat(4)@(negedge clk);rst=0;repeat(4)@(negedge clk);
    check(33'sd0,32'd48000,9'd0);
    check(33'sd48000,32'd192000,9'd80);
    check(33'sd1048576,32'd4194304,9'd80);
    check(33'sd2147483648,32'hffffffff,9'd160);
    check(-33'sd96000,32'd192000,9'd0);
    check(33'sd48000,32'd0,9'd0);
    check(33'sd192000,32'd192000,9'd320);
    check(33'sd4294967295,32'd192000,9'd320);
    $display("PASS compact progress: high words, zero/negative, quarter/half/full song, 320px clamp, BLOCK_HUD=%0d",BLOCK_HUD);
    $finish;
end
initial begin #3000000;$fatal(1,"compact progress timeout");end
endmodule
