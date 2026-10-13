`timescale 1ns/1ps
module tb_hold_glow_fix;
reg clk=0;always #20 clk=~clk;
reg rst=1,de=0,vs=0;
reg signed [32:0] time_now=48000;
wire [4:0] index;reg [31:0] start,finish;
wire on,light,capture;wire [23:0] color,rgb;
reg [9:0] input_x=0,x1=0,x2=0;reg [8:0] input_y=0,y1=0,y2=0;reg d1=0,d2=0;
wire [23:0] backdrop=(input_x[5]^input_y[5]) ? 24'h80a0c0 : 24'hc08060;
rhythm_game_renderer #(.BLOCK_GEOMETRY(1),.STREAM_METADATA(1),.BLOCK_HUD(1)) renderer(
    .clk(clk),.rst(rst),.enabled(1'b1),.de(de),.vs(vs),.song_time(time_now),.song_frames(32'd480000),
    .state(4'd6),.error_code(4'd0),.auto_mode(1'b0),.score(20'd0),.combo(16'd0),.max_combo(16'd0),
    .perfect_count(16'd0),.good_count(16'd0),.bad_count(16'd0),.miss_count(16'd0),
    .metadata_valid(1'b0),.metadata_data(8'd0),.metadata_address(),.title(192'd0),.difficulty(128'd0),
    .view_index(index),.view_valid(index[2:0]==0),.view_start(start),.view_end(finish),.holding_mask(4'b0110),
    .input_down(4'b0110),.input_press(4'd0),.capture_busy(capture),.frame_enabled(),
    .pixel_on(on),.pixel_light(light),.pixel_rgb(color));
video_presentation #(.ENABLE_RHYTHM(1),.INITIAL_WARMUP_FRAMES(0)) presentation(
    .clk(clk),.rst(rst),.display_valid(1'b1),.display_slot_async(3'd0),.display_switch_toggle_async(1'b0),
    .display_slot_applied_toggle(),.display_active(),.brightness_level_async(3'd4),
    .image_brightness_async(7'd50),.image_contrast_async(7'd50),.image_sharpness_async(7'd50),
    .image_selected_async(2'd0),.image_select_toggle_async(1'b0),.image_adjust_toggle_async(1'b0),
    .spectrum_bands(256'd0),.spectrum_bars(640'd0),.spectrum_radius(8'd100),
    .spectrum_read_address(),.spectrum_read_data(8'd0),.spectrum_read_valid(1'b0),.spectrum_active(1'b0),
    .game_active(1'b1),.game_pixel_on(on),.game_pixel_light(light),.game_pixel_rgb(color),
    .touch_frame_packet(40'd0),.de(de),.vs(vs),.rgb_in(backdrop),.rgb_out(rgb));
always @*begin
    case(index[4:3])
        0:start=72000;1,2:start=48000;default:start=49800;
    endcase
    finish=index==8 ? 72000 : index==16 ? 96000 : start;
end
reg inspect_geometry=1;
always @(posedge clk)if(inspect_geometry && renderer.geo_we && (index==8 || index==16))begin
    if(renderer.geo_data[18:10]!=384)$fatal(1,"held head moved");
    if(index==8 && time_now==48000 && renderer.geo_data[8:0]!=253)$fatal(1,"0.5s body not100px");
    if(index==16 && time_now==48000 && renderer.geo_data[8:0]!=153)$fatal(1,"1s body not200px");
    if(index==8 && time_now==72000 && renderer.geo_data[8:0]!=353)$fatal(1,"Hold body vanished before end");
end
task frame;begin @(negedge clk);vs=1;@(negedge clk);vs=0;repeat(4000)@(negedge clk);if(capture)$fatal(1,"capture overrun");end endtask
integer xx,yy,f,pixels=0;reg save=0;reg [23:0] base;
always @(posedge clk)begin d1<=de;d2<=d1;x1<=input_x;y1<=input_y;x2<=x1;y2<=y1;end
always @(negedge clk)if(save && d2)begin
    $fwrite(f,"%c%c%c",rgb[23:16],rgb[15:8],rgb[7:0]);pixels=pixels+1;
    if(y2==300 && (x2==263 || x2==264 || x2==265) && rgb!==24'h994900)$fatal(1,"orange body/extra center stripe");
    if(y2==230 && (x2==375 || x2==376 || x2==377) && rgb!==24'h8e143d)$fatal(1,"pink body/extra center stripe");
    if(y2==366 && x2==264 && rgb!==24'hffffff)$fatal(1,"Hold head glyph not opaque");
    if(y2==384 && x2==225 && rgb!==24'hffffff)$fatal(1,"judge line not opaque");
    if(y2==360 && (x2==208 || x2==225))begin
        base=(x2[5]^y2[5]) ? 24'h202830 : 24'h302018;
        if(rgb[23:16]<base[23:16] || rgb[15:8]<base[15:8] || rgb[7:0]<base[7:0])$fatal(1,"dark glow frame remains");
    end
end
initial begin
    repeat(4)@(negedge clk);rst=0;repeat(12)@(negedge clk);frame;
    f=$fopen("prj/log/hold_glow_fix_20261012/fixed.ppm","wb");$fwrite(f,"P6\n640 480\n255\n");save=1;
    for(yy=0;yy<480;yy=yy+1)begin
        for(xx=0;xx<640;xx=xx+1)begin @(negedge clk);de=1;input_x=xx;input_y=yy;end
        @(negedge clk);de=0;repeat(160)@(negedge clk);
    end
    repeat(3)@(negedge clk);save=0;$fclose(f);if(pixels!=307200)$fatal(1,"frame pixel count");
    time_now=72000;frame;
    $display("PASS actual Hold/glow: 100/200px bodies, end alignment, no center stripe, background-safe glow, opaque glyph/line, 307200 rendered pixels");$finish;
end
initial begin #100000000;$fatal(1,"timeout");end
endmodule
