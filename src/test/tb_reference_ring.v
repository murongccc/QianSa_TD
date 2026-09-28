`timescale 1ns/1ps
// 参考模式必须直接选中对应柱，不能再套 32 段插值或首尾收短。
module tb_reference_ring;
reg clk=0,rst=1,frame_start=0;
reg [9:0] pixel_x=320,pixel_y=240;
reg [639:0] bars=0;
wire pixel_on;
wire [23:0] pixel_rgb;
integer i,x,y,expected_offset;
integer previous_radius=90;
reg radius_monitor_valid=0;
reg [6:0] observed_index;
reg [7:0] observed_level;
real angle;
always #5 clk=~clk;
ring_spectrum_renderer #(.REFERENCE_MODE(1)) dut(
    .clk(clk),.rst(rst),.frame_start(frame_start),.pixel_x(pixel_x),.pixel_y(pixel_y),.bands(256'd0),
    .bars(bars),.pixel_on(pixel_on),.pixel_rgb(pixel_rgb));
always @(posedge clk) begin
    #1;
    if(!rst && radius_monitor_valid && dut.base_radius!=previous_radius && !frame_start)
        $fatal(1,"radius changed within a video frame");
    previous_radius=dut.base_radius;
    radius_monitor_valid=!rst;
end
task next_frame;
    begin
        @(negedge clk);frame_start=1;
        @(negedge clk);frame_start=0;
        repeat(85) @(negedge clk);
    end
endtask
initial begin
    repeat(3) @(negedge clk);rst=0;
    for(i=0;i<256;i=i+1) begin
        expected_offset=$rtoi(3.0*$ln(10.0*($exp(i/100.0)-1.0)+1.0)/$ln(2.0));
        if(expected_offset>20) expected_offset=20;
        if(dut.radius_offset(i[7:0])!==expected_offset[4:0])
            $fatal(1,"radius log curve mismatch level=%0d",i);
    end
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
    // 只有一柱有声时，其余弱柱也必须保持 8 像素最低高度。
    bars=640'd1;
    for(i=0;i<80;i=i+1) begin
        angle=6.283185307179586*i/80;
        x=$rtoi(320+97*$cos(angle)+0.5);y=$rtoi(240+97*$sin(angle)+0.5);
        @(negedge clk);pixel_x=x;pixel_y=y;
        @(posedge clk);#1;
        if(dut.bar_length!==6'd8 || !pixel_on)
            $fatal(1,"weak column minimum missing index=%0d",i);
    end
    @(negedge clk);pixel_x=419;pixel_y=240;
    @(posedge clk);#1;
    if(pixel_on) $fatal(1,"weak column exceeded minimum height");
    @(negedge clk);pixel_x=413;bars=0;
    @(posedge clk);#1;
    if(pixel_on) $fatal(1,"silent circle visible");
    // 最后一柱也必须参与峰值；扫描完成后下一帧才更新半径。
    bars=0;bars[79*8 +:8]=8'd200;
    next_frame;
    if(dut.base_radius!==8'd90 || dut.g_breath.pending_peak!==8'd200)
        $fatal(1,"peak scan/frame delay mismatch");
    next_frame;
    if(dut.g_breath.peak_envelope!==8'd163 || dut.base_radius!==8'd106)
        $fatal(1,"reference envelope/radius curve mismatch");
    next_frame;next_frame;next_frame;
    if(dut.base_radius!==8'd108) $fatal(1,"steady loud radius mismatch");
    // 内圆和圆帽一起移动，零幅度柱仍保持 8 px，旧内圆位置应消失。
    @(negedge clk);pixel_x=435;pixel_y=240;
    @(posedge clk);#1;
    if(!pixel_on || dut.bar_length!==6'd8) $fatal(1,"breathing weak column missing");
    @(negedge clk);pixel_x=420;
    @(posedge clk);#1;
    if(pixel_on) $fatal(1,"old inner radius did not move");
    bars={80{8'd255}};
    next_frame;next_frame;next_frame;
    if(dut.base_radius!==8'd110) $fatal(1,"radius upper limit mismatch");
    @(negedge clk);pixel_x=492;
    @(posedge clk);#1;
    if(!pixel_on) $fatal(1,"expanded maximum column clipped");
    @(negedge clk);pixel_x=494;
    @(posedge clk);#1;
    if(pixel_on) $fatal(1,"maximum column overflow");
    bars={80{8'd20}};
    next_frame;next_frame;next_frame;next_frame;
    if(dut.base_radius!==8'd95) $fatal(1,"weak music did not contract ring");
    bars=0;
    @(posedge clk);#1;
    if(pixel_on) $fatal(1,"breathing ring visible during silence");
    next_frame;next_frame;next_frame;next_frame;
    if(dut.base_radius!==8'd90) $fatal(1,"silence radius did not return to baseline");
    rst=1;@(negedge clk);rst=0;
    if(dut.base_radius!==8'd90 || dut.g_breath.peak_ready)
        $fatal(1,"breathing reset did not clear state");
    $display("PASS reference ring: 80 direct columns, 8 px floor, breathing envelope, frame boundary, bounds and silence");$finish;
end
endmodule
