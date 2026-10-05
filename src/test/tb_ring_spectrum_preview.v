`timescale 1ns/1ps
// 逐像素导出真实 RTL 输出；BANDS 来自音乐重放 CSV，禁止用绘图模型替代 RTL。
module tb_ring_spectrum_preview;
parameter integer REFERENCE_MODE=0;
reg clk=0,rst=1;
reg [7:0] breath_radius=90;
reg [9:0] pixel_x=0,pixel_y=0;
reg [255:0] bands=0;
reg [639:0] bars=0;
wire pixel_on;
wire [23:0] pixel_rgb;
reg [2047:0] output_path;
integer x,y,out_file,radius_argument;
always #5 clk=~clk;
ring_spectrum_renderer #(.REFERENCE_MODE(REFERENCE_MODE)) dut(.bars_read_address(),.bars_read_data(8'd0),.bars_read_valid(1'b0),.bars_active(1'b0),
    .clk(clk),.rst(rst),.breath_radius(breath_radius),.pixel_x(pixel_x),.pixel_y(pixel_y),
    .bands(bands),.bars(bars),.pixel_on(pixel_on),.pixel_rgb(pixel_rgb));
initial begin
    if (!$value$plusargs("FRAME=%s",output_path))
        $fatal(1,"missing preview arguments");
    if(REFERENCE_MODE) begin
        if(!$value$plusargs("BARS=%h",bars)) $fatal(1,"missing direct bars");
        if($value$plusargs("RADIUS=%d",radius_argument)) begin
            if(radius_argument<90 || radius_argument>110) $fatal(1,"invalid preview radius");
            breath_radius=radius_argument;
        end
    end else if(!$value$plusargs("BANDS=%h",bands)) $fatal(1,"missing bands");
    out_file=$fopen(output_path,"w");
    if (!out_file) $fatal(1,"cannot open preview output");
    $fwrite(out_file,"P3\n640 480\n255\n");
    repeat (2) @(negedge clk);rst=0;
    for (y=0;y<480;y=y+1)
        for (x=0;x<640;x=x+1) begin
            @(negedge clk);pixel_x=x;pixel_y=y;
            @(posedge clk);#1;
            if (pixel_on===1'b1) $fwrite(out_file,"%0d %0d %0d\n",pixel_rgb[23:16],pixel_rgb[15:8],pixel_rgb[7:0]);
            else if (pixel_on===1'b0) $fwrite(out_file,"8 13 24\n");
            else $fatal(1,"undefined preview pixel");
        end
    $fclose(out_file);
    $display("PASS RTL preview");$finish;
end
endmodule
