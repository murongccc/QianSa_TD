`timescale 1ns/1ps
module tb_touch_counter_increment;
reg [15:0] count=0;
wire [15:0] next_count;
wire [15:0] next_dsp_count;
integer i;
touch_counter_increment dut(.clk(1'b0),.rst(1'b0),.count(count),.next_count(next_count));
touch_counter_increment #(.USE_DSP(1)) dsp_dut(.clk(1'b0),.rst(1'b0),.count(count),.next_count(next_dsp_count));
initial begin
    for(i=0;i<65536;i=i+1)begin
        count=i[15:0];#1;
        if(next_count!==((i+1)&16'hffff) || next_dsp_count!==((i+1)&16'hffff))begin
            $display("FAIL counter count=%h next=%h",count,next_count);$stop;
        end
    end
    $display("PASS 16-bit counters: logic and DSP modes, all 65536 values including FFFF->0000");$finish;
end
endmodule
