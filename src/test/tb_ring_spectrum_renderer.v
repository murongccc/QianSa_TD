`timescale 1ns/1ps
module tb_ring_spectrum_renderer;
reg [9:0] pixel_x=320, pixel_y=240;
reg [255:0] bands=0;
reg clk=0,rst=1;
always #5 clk=~clk;
wire pixel_on;
wire [23:0] pixel_rgb;
integer i,j,x,y,k,r,visible_count,total,seam_a,seam_b;
integer visible_pixels [0:79];
integer frame_file;
reg [2047:0] frame_path;
reg [23:0] first_color;
real angle,dx,dy;
ring_spectrum_renderer dut (
    .clk(clk),.rst(rst),
    .pixel_x(pixel_x),.pixel_y(pixel_y),.bands(bands),
    .pixel_on(pixel_on),.pixel_rgb(pixel_rgb)
);
task point;
    input integer index;
    input integer radius;
    begin
        angle=6.283185307179586*index/80;
        dx=radius*$sin(angle); dy=radius*$cos(angle);
        if (dx>=0) dx=dx+0.5; else dx=dx-0.5;
        if (dy>=0) dy=dy+0.5; else dy=dy-0.5;
        pixel_x=320+$rtoi(dx); pixel_y=240-$rtoi(dy);
        @(posedge clk); #1;

    end
endtask
initial begin
    repeat (2) @(negedge clk); rst=0;
    // 对数重采样的两端为零，频段单调，半圈内主要展开低频。
    bands={32{8'd200}};
    point(20,91); if (dut.level!=0) $fatal(1,"virtual DC missing");
    point(19,91); if (dut.level!=0) $fatal(1,"end taper missing");
    point(60,91); if (dut.band_index>10) $fatal(1,"bass not expanded");
    j=0;
    for (i=0;i<80;i=i+1) begin
        point((i+20)%80,91);
        if (dut.band_index<j) $fatal(1,"frequency order reversed");
        j=dut.band_index;
    end
    // 检查插值，最高段和最低段不混合；每个真实频段均影响至少一根柱。
    for (j=0;j<32;j=j+1) begin
        bands=0; bands[j*8 +: 8]=200; visible_count=0;
        for (i=0;i<80;i=i+1) begin
            point(i,91);
            if (dut.level>0) visible_count=visible_count+1;
        end
        if (!visible_count) $fatal(1,"band %0d unused",j);
    end
    bands=256'd1;
    for (j=0;j<80;j=j+1) visible_pixels[j]=0;
    total=0;
    for (y=72;y<=408;y=y+1)
        for (x=152;x<=488;x=x+1) begin
            pixel_x=x; pixel_y=y; @(posedge clk); #1;
            if (pixel_on) begin
                visible_pixels[dut.sector]=visible_pixels[dut.sector]+1;
                total=total+1;
                if (dut.distance_sq<8100 || dut.distance_sq>8464 || !dut.inside_side_stage)
                    $fatal(1,"short bar bounds violated");
            end
        end
    for (j=0;j<80;j=j+1)
        if (!visible_pixels[j]) $fatal(1,"missing short bar %0d",j);
    if (total>900) $fatal(1,"bars excessively wide %0d",total);
    // 满幅中心线连续，柱间隙不随半径变为宽扇形；圆帽两侧缩短。
    bands={32{8'd255}};
    for (i=0;i<80;i=i+1) begin
        point(i,110);
        if (dut.sector!==i[6:0]) $fatal(1,"sector mismatch %0d",i);
        if (dut.bar_length>20 && !pixel_on) $fatal(1,"missing full bar %0d",i);
    end
    // index20 为视觉起点，选顶部 index0 检查恒定宽度和圆帽。
    point(0,100); first_color=pixel_rgb;
    r=dut.outer_radius;
    pixel_x=320; pixel_y=240-r; @(posedge clk); #1;
    if (!pixel_on) $fatal(1,"cap center missing");
    pixel_x=321; @(posedge clk); #1;
    if (pixel_on) $fatal(1,"cap side not rounded");
    pixel_y=240-r+2; @(posedge clk); #1;
    if (!pixel_on) $fatal(1,"bar side missing");
    pixel_x=323; @(posedge clk); #1;
    if (pixel_on) $fatal(1,"bar width too large");
    point(40,100); if (pixel_rgb==first_color) $fatal(1,"rainbow missing");
    // 可选导出 RTL 逐像素结果供视觉检查。
    if ($value$plusargs("FRAME=%s",frame_path)) begin
        bands=0;
        for (j=0;j<32;j=j+1) begin
            k=45+(31-j)*3;
            if (j==1 || j==2 || j==5) k=k+50;
            bands[j*8 +: 8]=k;
        end
        frame_file=$fopen(frame_path,"w");
        if (!frame_file) $fatal(1,"cannot open PPM");
        $fwrite(frame_file,"P3\n640 480\n255\n");
        for (y=0;y<480;y=y+1)
            for (x=0;x<640;x=x+1) begin
                pixel_x=x;pixel_y=y;@(posedge clk); #1;
                if (pixel_on) $fwrite(frame_file,"%0d %0d %0d\n",pixel_rgb[23:16],pixel_rgb[15:8],pixel_rgb[7:0]);
                else $fwrite(frame_file,"8 13 24\n");
            end
        $fclose(frame_file);
    end
    // 数据流水不复位时，有效标志仍必须立即屏蔽可见输出。
    bands={32{8'd255}};point(0,100);
    rst=1;#1;
    if (pixel_on!==1'b0) $fatal(1,"reset did not hide pipelined ring");
    repeat (2) @(negedge clk);rst=0;
    bands=0;
    for (y=72;y<=408;y=y+1)
        for (x=152;x<=488;x=x+1) begin
            pixel_x=x;pixel_y=y;@(posedge clk); #1;
            if (pixel_on) $fatal(1,"silence visible");
        end
    $display("PASS ring: 80 sectors, logarithmic order, all 32 bands, seam taper, thin caps, floor, silence");
    $finish;
end
endmodule
