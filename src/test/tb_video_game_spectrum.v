`timescale 1ns/1ps
// 真实扫描时序验证两拍合成、帧边界模式切换和没有底图时的游戏频谱。
module tb_video_game_spectrum;
reg clk=0,rst=1,de=0,vs=0,game=1,display_valid=1;
always #20 clk=~clk;
reg [9:0] x=0,y=0;
reg [7:0] data;
wire [6:0] address;
wire [23:0] rgb;
reg source_on=0,source_light=0;
reg [23:0] source_rgb=0;
wire opaque=(x>=550 && x<565 && y>=232 && y<248);
wire light=(x>=565 && x<580 && y>=232 && y<248);
always @(posedge clk)begin
    source_on<=de && (opaque || light);source_light<=light;source_rgb<=24'h804020;
    data<=8'd255;
end
video_presentation #(.REFERENCE_SPECTRUM(1),.BLOCK_BARS(1),.ENABLE_RHYTHM(1),.INITIAL_WARMUP_FRAMES(0)) dut(
    .clk(clk),.rst(rst),.display_valid(display_valid),.info_frame_start(),.info_slot(),.display_info(89'd0),.display_slot_async(3'd0),.display_switch_toggle_async(1'b0),
    .display_slot_applied_toggle(),.display_active(),
    .image_brightness_async(7'd50),.image_contrast_async(7'd50),.image_sharpness_async(7'd50),
    .image_selected_async(2'd0),
    .spectrum_bands(256'd0),.spectrum_bars(640'd0),.spectrum_radius(8'd110),
    .spectrum_read_address(address),.spectrum_read_data(data),.spectrum_read_valid(1'b1),.spectrum_active(1'b1),
    .game_active(game),.game_pixel_on(source_on),.game_pixel_light(source_light),.game_pixel_rgb(source_rgb),
    .touch_frame_packet(40'd0),.de(de),.vs(vs),.rgb_in(24'h808080),.rgb_out(rgb));
reg d1=0,d2=0;
reg [9:0] x1=0,y1=0,x2=0,y2=0;
reg check=0,expected_game=1;
reg [23:0] expected;
integer pixels=0,spectrum_pixels=0,opaque_hits=0,light_hits=0;
always @(posedge clk)begin
    d1<=de;d2<=d1;x1<=x;y1<=y;x2<=x1;y2<=y1;
    if(check && d1)begin
        if(dut.game_stage!==expected_game)$fatal(1,"game stage switched mid-frame");
        if(expected_game)begin
            expected=dut.spectrum_on ? dut.spectrum_rgb : (dut.base_valid_stage ? 24'h282828 : 24'd0);
            if(source_on)expected=source_light ? expected | source_rgb : source_rgb;
            if(dut.spectrum_on)begin
                spectrum_pixels=spectrum_pixels+1;
                if(x1<368 || x1>608 || y1<120 || y1>360)$fatal(1,"composite ring wrong position at %d/%d",x1,y1);
                if(source_on)begin
                    if(source_light)light_hits=light_hits+1;else opaque_hits=opaque_hits+1;
                end
            end
            if(y1==240 && x1==608 && !dut.spectrum_on)$fatal(1,"rightmost spectrum endpoint");
        end else expected=!dut.base_valid_stage ? 24'd0 :
            dut.spectrum_on ? dut.spectrum_rgb : dut.adjusted_rgb_stage;
        #1;
        if(rgb!==expected)$fatal(1,"game spectrum composite misaligned at %d/%d got=%h expected=%h",x1,y1,rgb,expected);
        pixels=pixels+1;
    end
end
task frame_start;begin
    @(negedge clk);vs=1;@(negedge clk);vs=0;repeat(16)@(negedge clk);
end endtask
task scan;
input integer mode;
integer px,py;
begin
    expected_game=mode;check=1;
    for(py=0;py<480;py=py+1)begin
        for(px=0;px<640;px=px+1)begin
            @(negedge clk);x=px;y=py;de=1;
            // 帧中要求进入/退出游戏，必须等到下次帧边界才生效。
            if(py==100 && px==200)game=!mode;
        end
        @(negedge clk);de=0;repeat(160)@(negedge clk);
    end
    repeat(4)@(negedge clk);check=0;
end endtask
initial begin
    repeat(4)@(negedge clk);rst=0;repeat(16)@(negedge clk);
    frame_start;scan(1);
    if(opaque_hits==0 || light_hits==0 || spectrum_pixels<5000)$fatal(1,"overlay priorities not exercised");
    frame_start;if(dut.u_ring_spectrum_renderer.CENTER_X!=320)$fatal(1,"normal center not restored");scan(0);
    display_valid=0;repeat(16)@(negedge clk);frame_start;scan(1);
    if(pixels!=921600)$fatal(1,"composite sample count %d",pixels);
    $display("PASS game spectrum composite: 921600 pixels, opaque/light priority, two-cycle alignment, frame-only transitions, spectrum without BMP");
    $finish;
end
initial begin #100000000;$fatal(1,"game spectrum timeout");end
endmodule
