`timescale 1ns/1ps
module tb_touch_counter_increment;
reg [15:0] count=0;
wire [15:0] next_count;
integer i;
touch_counter_increment dut(.clk(1'b0),.rst(1'b0),.count(count),.next_count(next_count));
initial begin
    for(i=0;i<65536;i=i+1)begin
        count=i[15:0];#1;
        if(next_count!==((i+1)&16'hffff))begin
            $display("FAIL counter count=%h next=%h",count,next_count);$stop;
        end
    end
    $display("PASS DSP counter: all 65536 values including FFFF->0000");$finish;
end
endmodule
