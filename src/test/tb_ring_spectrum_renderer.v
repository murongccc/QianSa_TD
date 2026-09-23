`timescale 1ns/1ps

module tb_ring_spectrum_renderer;
reg [9:0] pixel_x=10'd320, pixel_y=10'd240;
reg [255:0] bands=0;
wire pixel_on;
wire [23:0] pixel_rgb;
reg [23:0] top_color;
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
    $display("PASS ring renderer: silence, no baseline, round edge, radial limit, color");
    $finish;
end
endmodule
