`timescale 1ns/1ps
module tb_touch_pixel_mapper;
reg clk=0;always #10 clk=~clk;
reg rst=1,update_valid=0,a_down=0,b_down=0;
reg [15:0] a_x=0,a_y=0,b_x=0,b_y=0;
wire pixel_valid;wire [39:0] packet;
reg [39:0] last_packet;
integer vectors=0,v,phase,wait_cycles;
integer previous_x=0;
touch_pixel_mapper dut(.clk(clk),.rst(rst),.update_valid(update_valid),
    .a_down(a_down),.a_x(a_x),.a_y(a_y),.b_down(b_down),.b_x(b_x),.b_y(b_y),
    .pixel_valid(pixel_valid),.pixel_packet(packet),.busy());
task fail;input [511:0] message;begin $display("FAIL %0s vector=%0d",message,vectors);$stop;end endtask
function [9:0] reference_x;
    input integer raw;
    integer delta;
    begin
        if(raw<96)delta=0;else if(raw>16144)delta=16048;else delta=raw-96;
        reference_x=(delta*2610+32768)/65536;
    end
endfunction
function [8:0] reference_y;
    input integer raw;
    integer delta;
    begin
        if(raw<128)delta=0;else if(raw>9440)delta=9312;else delta=raw-128;
        reference_y=(delta*3371+32768)/65536;
    end
endfunction
always @(negedge clk)begin
    if(rst)last_packet=40'd0;
    else begin
        if(!pixel_valid && packet!==last_packet)fail("partial packet published");
        last_packet=packet;
    end
end
task check_result;
    reg [39:0] expected;
    begin
        wait_cycles=0;
        while(!pixel_valid && wait_cycles<20)begin @(negedge clk);#1;wait_cycles=wait_cycles+1;end
        expected={a_down,b_down,reference_x(a_x),reference_y(a_y),reference_x(b_x),reference_y(b_y)};
        if(!pixel_valid || packet!==expected)begin $display("expected=%h actual=%h",expected,packet);fail("mapping result/latency");end
        vectors=vectors+1;
    end
endtask
task map;
    input integer ax,ay,bx,by;
    input [1:0] down;
    begin
        @(negedge clk);a_x=ax[15:0];a_y=ay[15:0];b_x=bx[15:0];b_y=by[15:0];
        a_down=down[1];b_down=down[0];update_valid=1;
        @(negedge clk);update_valid=0;#1;check_result;
    end
endtask
integer exact_x,exact_y,delta_x,delta_y,error_x,error_y;
initial begin #100000000;fail("timeout");end
initial begin
    repeat(3)@(negedge clk);rst=0;
    map(96,128,16144,9440,2'b11);
    if(packet[37:28]!=0 || packet[27:19]!=0 || packet[18:9]!=639 || packet[8:0]!=479)fail("endpoints");
    map(8096,4816,7888,4528,2'b11);
    if(packet[37:28]!=319 || packet[27:19]!=241 || packet[18:9]!=310 || packet[8:0]!=226)fail("calibration centers");
    // 全部 16 位原始输入；同时覆盖两点、两个轴、按住及松开和边界钳位。
    for(v=0;v<65536;v=v+1)begin
        map(v,v,65535-v,65535-v,v[1:0]);
        if(packet[37:28]<previous_x)fail("non-monotonic X");
        previous_x=packet[37:28];
        delta_x=v<96 ? 0 : v>16144 ? 16048 : v-96;
        delta_y=v<128 ? 0 : v>9440 ? 9312 : v-128;
        exact_x=(delta_x*639+8024)/16048;exact_y=(delta_y*479+4656)/9312;
        error_x=packet[37:28]-exact_x;error_y=packet[27:19]-exact_y;
        if(error_x>1 || error_x< -1 || error_y>1 || error_y< -1)fail("fixed-point error exceeds one pixel");
    end
    // 在四坐标计算的每个阶段重新提交数据，结果只能是最后一份完整快照。
    for(phase=0;phase<12;phase=phase+1)begin
        @(negedge clk);a_x=96;a_y=128;b_x=16144;b_y=9440;a_down=1;b_down=1;update_valid=1;
        @(negedge clk);update_valid=0;
        repeat(phase)@(negedge clk);
        @(negedge clk);a_x=8096;a_y=4816;b_x=752;b_y=512;a_down=0;b_down=1;update_valid=1;
        @(negedge clk);update_valid=0;#1;check_result;
    end
    @(negedge clk);update_valid=1;
    @(negedge clk);update_valid=0;
    repeat(4)@(negedge clk);rst=1;#1;
    if(packet!==40'd0 || pixel_valid)fail("reset during mapping");
    repeat(3)@(negedge clk);rst=0;map(65535,0,0,65535,2'b00);
    $display("PASS mapper: %0d vectors, 65536 raw values, endpoints, rounding, atomic restart and reset",vectors);
    $finish;
end
endmodule
