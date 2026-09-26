`timescale 1ns/1ps

module tb_ring_spectrum_renderer;
reg [9:0] pixel_x=10'd320, pixel_y=10'd240;
reg [255:0] bands=0;
wire pixel_on;
wire [23:0] pixel_rgb;
reg [23:0] top_color;
integer i;
integer center_x, center_y;
real angle;
ring_spectrum_renderer dut (
    .pixel_x(pixel_x), .pixel_y(pixel_y), .bands(bands),
    .pixel_on(pixel_on), .pixel_rgb(pixel_rgb)
);

task expect_pixel;
    input [9:0] x, y;
    input expected;
    begin
        pixel_x=x; pixel_y=y; #1;
        if (pixel_on !== expected)
            $fatal(1,"ring pixel (%0d,%0d) got %b expected %b",x,y,pixel_on,expected);
    end
endtask

initial begin
    expect_pixel(10'd320,10'd240,1'b0);
    expect_pixel(10'd320,10'd150,1'b0);
    expect_pixel(10'd410,10'd240,1'b0);
    expect_pixel(10'd320,10'd330,1'b0);
    expect_pixel(10'd230,10'd240,1'b0);
    expect_pixel(10'd320,10'd149,1'b0);
    expect_pixel(10'd438,10'd122,1'b0);
    bands[0*8 +: 8]=8'hff;
    bands[8*8 +: 8]=8'hff;
    bands[16*8 +: 8]=8'hff;
    bands[24*8 +: 8]=8'hff;
    bands[4*8 +: 8]=8'hff;
    expect_pixel(10'd320,10'd150,1'b0);
    expect_pixel(10'd410,10'd240,1'b0);
    expect_pixel(10'd320,10'd330,1'b0);
    expect_pixel(10'd230,10'd240,1'b0);
    expect_pixel(10'd320,10'd149,1'b1);
    expect_pixel(10'd320,10'd72,1'b1);
    top_color=pixel_rgb;
    expect_pixel(10'd488,10'd240,1'b1);
    if (pixel_rgb == top_color) $fatal(1,"rainbow has identical quadrant colors");
    expect_pixel(10'd320,10'd408,1'b1);
    expect_pixel(10'd152,10'd240,1'b1);
    expect_pixel(10'd438,10'd122,1'b1);
    expect_pixel(10'd439,10'd121,1'b0);
    expect_pixel(10'd440,10'd120,1'b0);
    expect_pixel(10'd320,10'd71,1'b0);
    expect_pixel(10'd320,10'd430,1'b0);
    expect_pixel(10'd576,10'd240,1'b0);
    // 满幅时遍历全部 64 个柱中心，确认角度编号与柱间间隙。
    bands={32{8'hff}};
    for (i=0;i<64;i=i+1) begin
        angle=6.283185307179586*i/64;
        center_x=320+$rtoi(140*$sin(angle));
        center_y=240-$rtoi(140*$cos(angle));
        expect_pixel(center_x,center_y,1'b1);
        if (dut.sector !== i[5:0]) $fatal(1,"sector mismatch %0d",i);
    end
    expect_pixel(10'd328,10'd80,1'b0);
    bands=0;
    bands[0*8 +: 8]=8'd200;
    bands[1*8 +: 8]=8'd40;
    bands[31*8 +: 8]=8'd80;
    expect_pixel(10'd332,10'd120,1'b1);
    if (dut.sector !== 6'd1 || dut.level !== 8'd120)
        $fatal(1,"adjacent band interpolation failed");
    if (pixel_rgb !== 24'h2ed2ff) $fatal(1,"interpolated color failed");
    expect_pixel(10'd308,10'd120,1'b0);
    if (dut.sector !== 6'd63 || dut.level !== 8'd80)
        $fatal(1,"last bar must retain highest band without wrapping");
    $display("PASS ring renderer: 64 centers, interpolation, no frequency wrap, gaps, silence, round edge, color");
    $finish;
end
endmodule
