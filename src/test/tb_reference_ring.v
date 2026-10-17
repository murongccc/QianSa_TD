`timescale 1ns/1ps
// 渲染器只接收与音柱同步的半径；动态算法由 FFT 单元单独验证。
module tb_reference_ring;
reg clk=0,rst=1;
reg [7:0] breath_radius=90;
reg [9:0] pixel_x=320,pixel_y=240;
reg [639:0] bars=0;
wire pixel_on;
wire [23:0] pixel_rgb;
integer i,x,y,r,inner;
real angle;
always #5 clk=~clk;
ring_spectrum_renderer #(.REFERENCE_MODE(1)) dut(.game_layout(1'b0),.bars_read_address(),.bars_read_data(8'd0),.bars_read_valid(1'b0),.bars_active(1'b0),
    .clk(clk),.rst(rst),.breath_radius(breath_radius),.pixel_x(pixel_x),.pixel_y(pixel_y),
    .bands(256'd0),.bars(bars),.pixel_on(pixel_on),.pixel_rgb(pixel_rgb));
initial begin
    repeat(3) @(negedge clk);rst=0;
    for(i=0;i<80;i=i+1) begin
        bars=0;bars[i*8 +:8]=8'd160;
        angle=6.283185307179586*i/80;
        x=$rtoi(320+110*$cos(angle)+0.5);y=$rtoi(240+110*$sin(angle)+0.5);
        @(negedge clk);pixel_x=x;pixel_y=y;
        @(posedge clk);#1;
        if(dut.display_index!==i[6:0] || dut.level_stage!==8'd160 || !pixel_on)
            $fatal(1,"direct bar index/geometry mismatch %0d",i);
    end
    bars=640'd1;
    for(r=90;r<=110;r=r+1) begin
        @(negedge clk);breath_radius=r;inner=r-10;
        #1;
        if(dut.base_radius!==inner || dut.base_radius_sq!==inner*inner)
            $fatal(1,"picture radius/square mismatch r=%0d",r);
        if(dut.side_limit!==9'd384 || dut.cap_limit!==9'd192)
            $fatal(1,"picture bar width changed");
        for(i=0;i<80;i=i+1) begin
            angle=6.283185307179586*i/80;
            x=$rtoi(320+(inner+7)*$cos(angle)+0.5);y=$rtoi(240+(inner+7)*$sin(angle)+0.5);
            @(negedge clk);pixel_x=x;pixel_y=y;
            @(posedge clk);#1;
            if(dut.bar_length!==6'd8 || !pixel_on)
                $fatal(1,"8 px floor missing radius=%0d column=%0d",r,i);
        end
        @(negedge clk);pixel_x=320+inner-1;pixel_y=240;
        @(posedge clk);#1;
        if(pixel_on) $fatal(1,"pixel inside inner radius");
        @(negedge clk);pixel_x=320+inner+9;
        @(posedge clk);#1;
        if(pixel_on) $fatal(1,"weak bar exceeded outer radius");
    end
    bars={80{8'd255}};
    @(negedge clk);pixel_x=482;
    @(posedge clk);#1;
    if(!pixel_on) $fatal(1,"expanded strongest column clipped");
    @(negedge clk);pixel_x=484;
    @(posedge clk);#1;
    if(pixel_on) $fatal(1,"maximum column overflow");
    bars=0;
    @(posedge clk);#1;
    if(pixel_on) $fatal(1,"silent circle visible");
    $display("PASS reference ring: 80 columns, all breathing radii, 8 px floor, bounds and silence");$finish;
end
endmodule
