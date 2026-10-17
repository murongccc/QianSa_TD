`timescale 1ns/1ps
// 默认启用Logo的真实呈现链，与关闭Logo的同输入链逐像素比较。
module tb_video_logo;
reg clk=0,rst=1,de=0,vs=0,game=0,valid=0,toggle=0;
always #5 clk=~clk;
reg [6:0] brightness=50,contrast=50;
wire game_on,game_light;
wire [23:0] game_rgb,rgb,reference_rgb;
wire [4:0] view_index;
wire [5:0] metadata_address;
wire [23:0] background={8'h60,8'h90,8'hc0};
rhythm_game_renderer #(.BLOCK_GEOMETRY(1),.BLOCK_HUD(1),.STREAM_METADATA(1)) renderer(
    .clk(clk),.rst(rst),.enabled(game),.de(de),.vs(vs),
    .song_time(33'sd0),.song_frames(32'd480000),.state(4'd6),.error_code(4'd0),.auto_mode(1'b0),
    .score(20'd12345),.combo(16'd12),.max_combo(16'd12),.perfect_count(16'd12),
    .good_count(16'd0),.bad_count(16'd0),.miss_count(16'd0),
    .metadata_valid(1'b0),.metadata_data(8'd0),.metadata_address(metadata_address),
    .title(192'd0),.difficulty(128'd0),.view_index(view_index),.view_valid(1'b0),
    .view_start(32'd0),.view_end(32'd0),.holding_mask(4'd0),.input_down(4'd0),.input_press(4'd0),
    .capture_busy(),.frame_enabled(),.pixel_on(game_on),.pixel_light(game_light),.pixel_rgb(game_rgb));
`define PRESENTATION_PORTS \
    .clk(clk),.rst(rst),.display_valid(valid),.display_slot_async(3'd0),.display_info(89'd0), \
    .info_frame_start(),.info_slot(),.display_switch_toggle_async(toggle),.display_slot_applied_toggle(),.display_active(), \
    .image_brightness_async(brightness),.image_contrast_async(contrast),.image_sharpness_async(7'd50),.image_selected_async(2'd0), \
    .spectrum_bands(256'd0),.spectrum_bars(640'd0),.spectrum_radius(8'd90),.spectrum_read_address(), \
    .spectrum_read_data(8'd0),.spectrum_read_valid(1'b0),.spectrum_active(1'b0), \
    .game_active(game),.game_pixel_on(game_on),.game_pixel_light(game_light),.game_pixel_rgb(game_rgb), \
    .touch_frame_packet(40'd0),.de(de),.vs(vs),.rgb_in(background)
video_presentation #(.ENABLE_RHYTHM(1),.INITIAL_WARMUP_FRAMES(0)) dut(
    `PRESENTATION_PORTS,.rgb_out(rgb));
video_presentation #(.ENABLE_RHYTHM(1),.ENABLE_LOGO(0),.INITIAL_WARMUP_FRAMES(0)) reference(
    `PRESENTATION_PORTS,.rgb_out(reference_rgb));
`undef PRESENTATION_PORTS
reg [24:0] expected[0:2015];
integer x,y,phase,file_id,opaque_count,transparent_count,pause_count,total=0;
reg [24:0] sample;
reg [1023:0] filename;
task check_pixel;
    input integer px,py;
    begin
        sample=25'd0;
        if(px>=8 && px<64 && py>=8 && py<44)sample=expected[(py-8)*56+(px-8)];
        if(sample[24])begin
            if(rgb!==sample[23:0])$fatal(1,"logo color/alignment phase=%0d at %0d,%0d: %h expected %h",phase,px,py,rgb,sample);
            opaque_count=opaque_count+1;
        end else begin
            if(rgb!==reference_rgb)$fatal(1,"transparent/outside pixel changed phase=%0d at %0d,%0d: %h expected %h",phase,px,py,rgb,reference_rgb);
            if(px>=8 && px<64 && py>=8 && py<44)transparent_count=transparent_count+1;
        end
        if(game && px>=80 && px<100 && py>=16 && py<36)begin
            if(px<86 || px>=94)begin
                if(rgb!==24'hffffff)$fatal(1,"pause bars missing/misaligned at %0d,%0d",px,py);
                pause_count=pause_count+1;
            end else if(rgb!==24'h1e2d3c)$fatal(1,"pause gap filled at %0d,%0d",px,py);
        end
        // 旧暂停位置在Logo下面，用原始游戏渲染输出来确认旧双竖线已移除。
        if(game && px>=24 && px<44 && py>=18 && py<38 && renderer.base_pixel_on)
            $fatal(1,"old pause symbol remains at %0d,%0d",px,py);
        $fwrite(file_id,"%c%c%c",rgb[23:16],rgb[15:8],rgb[7:0]);
        total=total+1;
    end
endtask
task frame;
    begin
        @(negedge clk);vs=1;@(negedge clk);vs=0;repeat(5000)@(negedge clk);
        case(phase)
            0:filename="prj/log/video_logo_20261017/startup.ppm";
            1:filename="prj/log/video_logo_20261017/image.ppm";
            2:filename="prj/log/video_logo_20261017/game.ppm";
            default:filename="prj/log/video_logo_20261017/adjusted.ppm";
        endcase
        file_id=$fopen(filename,"wb");if(!file_id)$fatal(1,"preview open failed");
        $fwrite(file_id,"P6\n640 480\n255\n");opaque_count=0;transparent_count=0;pause_count=0;
        for(y=0;y<480;y=y+1)begin
            for(x=0;x<640;x=x+1)begin
                @(negedge clk);de=1;
                @(posedge clk);#1;if(x>0)check_pixel(x-1,y);
            end
            @(negedge clk);de=0;@(posedge clk);#1;check_pixel(639,y);
            repeat(160)@(negedge clk);
        end
        $fclose(file_id);
        if(opaque_count!=997 || transparent_count!=1019)$fatal(1,"logo coverage %0d/%0d",opaque_count,transparent_count);
        if(game && pause_count!=240)$fatal(1,"pause coverage %0d",pause_count);
    end
endtask
initial begin
    $readmemh("prj/log/video_logo_20261017/expected.hex",expected);
    repeat(4)@(negedge clk);rst=0;repeat(5)@(negedge clk);
    phase=0;frame;
    valid=1;repeat(5)@(negedge clk);phase=1;frame;
    game=1;phase=2;frame;
    game=0;brightness=75;contrast=25;toggle=1;repeat(5)@(negedge clk);phase=3;frame;
    // 复位清除窗口有效位，Logo不能在消隐期间留下残影。
    @(negedge clk);rst=1;@(posedge clk);#1;if(rgb!==24'd0 || dut.logo_hit_stage)$fatal(1,"reset output");
    $display("PASS logo 1228800 pixels: startup/image/game/adjustment/switch, transparency, pause bars/gap/old position, reset");
    $finish;
end
endmodule
