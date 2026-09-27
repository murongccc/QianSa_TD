`timescale 1ns/1ps
// 参考模式必须直接选中对应柱，不能再套 32 段插值或首尾收短。
module tb_reference_ring;
reg clk=0,rst=1;
reg [9:0] pixel_x=320,pixel_y=240;
reg [639:0] bars=0;
wire pixel_on;
wire [23:0] pixel_rgb;
integer i,x,y;
reg [6:0] observed_index;
reg [7:0] observed_level;
real angle;
always #5 clk=~clk;
ring_spectrum_renderer #(.REFERENCE_MODE(1)) dut(
    .clk(clk),.rst(rst),.pixel_x(pixel_x),.pixel_y(pixel_y),.bands(256'd0),
    .bars(bars),.pixel_on(pixel_on),.pixel_rgb(pixel_rgb));
initial begin
    repeat(3) @(negedge clk);rst=0;
    for(i=0;i<80;i=i+1) begin
        bars=0;bars[i*8 +:8]=8'd160;
        angle=6.283185307179586*i/80;
        x=$rtoi(320+110*$cos(angle)+0.5);y=$rtoi(240+110*$sin(angle)+0.5);
        @(negedge clk);pixel_x=x;pixel_y=y;
        @(posedge clk);#1;
        observed_index=dut.display_index;
        observed_level=dut.level_stage;
        if(observed_index!==i[6:0]) $fatal(1,"direct bar index=%0d actual=%0d",i,observed_index);
        if(observed_level!==8'd160 || !pixel_on) $fatal(1,"direct level or geometry index=%0d",i);
    end
    @(negedge clk);bars=0;
    @(posedge clk);#1;
    if(pixel_on) $fatal(1,"silent circle visible");
    $display("PASS reference ring 80 direct columns");$finish;
end
endmodule
