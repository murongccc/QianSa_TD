`timescale 1ns/1ps
// 实际视频呈现链逐像素检查右侧区域、中文/高亮颜色、原图旁路和帧边界元数据。
module tb_image_info_video;
reg clk=0,rst=1,de=0,vs=0,game=0,toggle=0;
always #5 clk=~clk;
reg [2:0] slot=0;
wire [88:0] info;
reg [88:0] expected_info={1'b1,16'h1920,16'h1080,28'h0003333,28'h0004444};
reg source_clk=0;always #3 source_clk=~source_clk;
reg source_start=0,source_commit=0;
reg [15:0] source_width=0,source_height=0;
reg [2:0] source_slot=0;
wire source_ready,info_frame_start;wire [2:0] info_slot;
image_info_metadata metadata(.clk(source_clk),.rst(rst),.start(source_start),.abort(1'b0),.commit(source_commit),
    .write_slot(source_slot),.source_width(source_width),.source_height(source_height),.ready(source_ready),
    .video_clk(clk),.video_rst(rst),.frame_start(info_frame_start),.display_slot(info_slot),.display_info(info));
reg [6:0] brightness=50,contrast=50;
reg [1:0] selected=0;
wire [23:0] rgb;
wire applied,active;
integer x,y,f,ink_pixels,yellow_pixels,frames;
reg [23:0] base;
// 独立检查右侧信息栏；Logo默认叠加及透明区域由tb_video_logo逐像素覆盖。
video_presentation #(.ENABLE_LOGO(0),.INITIAL_WARMUP_FRAMES(0)) dut(
    .clk(clk),.rst(rst),.display_valid(1'b1),.display_slot_async(slot),.info_frame_start(info_frame_start),.info_slot(info_slot),.display_info(info),
    .display_switch_toggle_async(toggle),.display_slot_applied_toggle(applied),.display_active(active),
    .image_brightness_async(brightness),.image_contrast_async(contrast),.image_sharpness_async(7'd50),.image_selected_async(selected),
    .spectrum_bands(256'd0),.spectrum_bars(640'd0),.spectrum_radius(8'd90),.spectrum_read_address(),
    .spectrum_read_data(8'd0),.spectrum_read_valid(1'b0),.spectrum_active(1'b0),
    .game_active(game),.game_pixel_on(1'b0),.game_pixel_light(1'b0),.game_pixel_rgb(24'd0),.touch_frame_packet(40'd0),
    .de(de),.vs(vs),.rgb_in(24'h6090c0),.rgb_out(rgb));
task boundary;
    begin
        @(negedge clk);vs=1;@(negedge clk);vs=0;repeat(16)@(negedge clk);
    end
endtask
task preload;
    input integer index,width,height;
    begin
        wait(source_ready);@(negedge source_clk);source_slot=index;source_width=width;source_height=height;source_start=1;
        @(negedge source_clk);source_start=0;repeat(170)@(negedge source_clk);
        source_commit=1;@(negedge source_clk);source_commit=0;repeat(20)@(negedge source_clk);
    end
endtask
task check_pixel;
    input integer px,py;
    reg [23:0] shade;
    begin
        shade={1'b0,base[23:17],1'b0,base[15:9],1'b0,base[7:1]};
        if(px<400 || px>=624 || py<16 || py>=176)begin
            if(rgb!==base)$fatal(1,"outside OSD/removed left OSD changed pixel %d,%d got %h expected %h",px,py,rgb,base);
        end else begin
            if(rgb===24'hffffff)ink_pixels=ink_pixels+1;
            else if(rgb===24'hffdf40)begin
                yellow_pixels=yellow_pixels+1;
                if((selected==0 && (py<120 || py>=136)) || (selected==1 && (py<144 || py>=160)))
                    $fatal(1,"highlight in wrong parameter row");
            end else if(rgb!==shade)$fatal(1,"panel shading/alignment %d,%d got %h expected %h",px,py,rgb,shade);
        end
        $fwrite(f,"%0d %0d %0d\n",rgb[23:16],rgb[15:8],rgb[7:0]);
    end
endtask
task capture;
    input [1023:0] filename;
    begin
        f=$fopen(filename,"w");if(!f)$fatal(1,"capture open");$fwrite(f,"P3\n640 480\n255\n");
        ink_pixels=0;yellow_pixels=0;
        for(y=0;y<480;y=y+1)begin
            for(x=0;x<640;x=x+1)begin
                @(negedge clk);de=1;
                @(posedge clk);#1;if(x>0)check_pixel(x-1,y);
            end
            @(negedge clk);de=0;@(posedge clk);#1;check_pixel(639,y);
            repeat(3)@(negedge clk);
        end
        $fclose(f);
        if(ink_pixels<500 || yellow_pixels<50)$fatal(1,"Chinese text or parameter highlight missing");
    end
endtask
initial begin
    repeat(3)@(negedge clk);rst=0;
    preload(0,1920,1080);preload(1,320,240);toggle=1;
    repeat(5)@(negedge clk);boundary;
    if(dut.active_info!==expected_info || dut.active_slot!=0 || !applied)$fatal(1,"initial info/slot commit");
    for(frames=0;frames<22;frames=frames+1)boundary;
    base=24'h6090c0;capture("prj/log/image_osd_20261014/default.ppm");
    // 参数快照只在帧边界刷新，值的十进制格式同时检查。
    brightness=75;contrast=25;selected=1;repeat(5)@(negedge clk);
    if(dut.g_image_info.u_osd.brightness_bcd!==12'h050)$fatal(1,"mid-frame parameter text change");
    boundary;
    if(dut.g_image_info.u_osd.brightness_bcd!==12'h075 || dut.g_image_info.u_osd.contrast_bcd!==12'h025 || dut.g_image_info.u_osd.selected_frame!=1)
        $fatal(1,"parameter snapshot");
    base={dut.image_adjust_component(8'h60,7'd75,7'd25),dut.image_adjust_component(8'h90,7'd75,7'd25),dut.image_adjust_component(8'hc0,7'd75,7'd25)};
    capture("prj/log/image_osd_20261014/adjusted.ppm");
    // 最后解析的尺寸及下一槽不能提前替换当前画面元数据。
    slot=1;expected_info={1'b1,16'h0320,16'h0240,28'h0020000,28'h0020000};toggle=0;
    repeat(5)@(negedge clk);
    if(dut.active_info===expected_info || dut.active_slot!=0)$fatal(1,"mid-frame metadata switch");
    boundary;if(dut.active_info!==expected_info || dut.active_slot!=1 || applied)$fatal(1,"metadata/slot not atomic");
    for(frames=0;frames<22;frames=frames+1)boundary;
    capture("prj/log/image_osd_20261014/switched.ppm");
    game=1;boundary;
    @(negedge clk);de=1;repeat(630)@(negedge clk);
    if(dut.info_panel_stage)$fatal(1,"image OSD visible in game");
    de=0;game=0;boundary;
    if(dut.g_image_info.u_osd.parameter_bcd(7'd100)!==12'h100 || dut.g_image_info.u_osd.parameter_bcd(7'd0)!==12'h000)$fatal(1,"parameter endpoints");
    if(dut.g_image_info.u_osd.ratio_char(28'h6400000,0)!==6'd38 || dut.g_image_info.u_osd.ratio_char(28'h0000033,4)!==6'd32)
        $fatal(1,"extreme ratio formatting");
    $display("PASS image video: 921600 pixels, Chinese OSD, parameter highlight/snapshot, no left OSD, atomic slot switch, game hide");$finish;
end
initial begin #20000000;$fatal(1,"image video timeout");end
endmodule
