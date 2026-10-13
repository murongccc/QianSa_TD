`timescale 1ns/1ps
// 对实际17拍串行换算器验证1.25倍速度、正负时间、像素边界和限幅。
module tb_rhythm_scroll_speed;
reg clk=0,rst=1;
always #20 clk=~clk;
reg [31:0] start=0,finish=0;
rhythm_game_renderer dut(
    .clk(clk),.rst(rst),.enabled(1'b0),.de(1'b0),.vs(1'b0),
    .song_time(33'sd0),.song_frames(32'd1),.state(4'd0),.error_code(4'd0),.auto_mode(1'b1),
    .score(20'd0),.combo(16'd0),.max_combo(16'd0),.perfect_count(16'd0),.good_count(16'd0),.bad_count(16'd0),.miss_count(16'd0),
    .metadata_valid(1'b0),.metadata_data(8'd0),.metadata_address(),.title(192'd0),.difficulty(128'd0),
    .view_index(),.view_valid(1'b1),.view_start(start),.view_end(finish),.holding_mask(4'd0),
    .input_down(4'd0),.input_press(4'd0),.capture_busy(),.frame_enabled(),.pixel_on(),.pixel_light(),.pixel_rgb());
integer cases=0,i,expected,amount;
reg [32:0] absolute_delta;
wire [9:0] observed_y=dut.converted_y;
wire [2:0] observed_work=dut.work;
task check;
    input signed [32:0] delta;
    input tail;
    begin
        @(negedge clk);
        start=32'd200000;finish=32'd200001;
        dut.time_snapshot=(tail ? 33'sd200001 : 33'sd200000)-delta;
        dut.which_end=tail;dut.work=3'd2;
        absolute_delta=delta<0 ? -delta : delta;
        amount=absolute_delta>33'd96000 ? 96000 : absolute_delta;
        amount=amount/240;
        if(delta<0)expected=amount>24 ? (tail ? 377 : 408) : (tail ? 353 : 384)+amount;
        else expected=amount>(tail ? 289 : 320) ? 64 : (tail ? 353 : 384)-amount;
        wait(observed_work==3'd4);
        if(observed_y!==expected)$fatal(1,"scroll delta=%0d tail=%0d got=%0d expected=%0d",delta,tail,observed_y,expected);
        cases=cases+1;
        @(negedge clk);dut.work=3'd0;
    end
endtask
initial begin
    repeat(4)@(negedge clk);rst=0;
    for(i=0;i<=400;i=i+1)begin
        check(i*240-1,0);check(i*240,0);check(i*240+1,0);
        check(-i*240-1,1);check(-i*240,1);check(-i*240+1,1);
    end
    check(24000,1);check(48000,1);check(131071,0);check(-131072,0);
    check(33'sd4294967295,0);check(-33'sd4294767294,1);
    $display("PASS scroll 1.25x: %0d actual serial conversions, 240-sample boundaries, signed time, Hold tails and clipping",cases);$finish;
end
initial begin #10000000;$fatal(1,"scroll timeout");end
endmodule
