`timescale 1ns/1ps
module tb_rhythm_renderer;
    reg clk=0;always #20 clk=~clk;
    reg rst=1,de=0,vs=0,enabled=1,display=1;
    reg signed [32:0] song_time=33'sd48000;reg [31:0] song_frames=32'd192000;
    reg [3:0] state=6;wire [4:0] vi;
    reg vv;reg [31:0] start,finish;
    wire capture,frame_active,on;wire [23:0] color,rgb;
    wire [5:0] meta_address;reg [7:0] meta_data=0;reg [7:0] meta_memory[0:63];
    always @(posedge clk)meta_data<=meta_memory[meta_address];
    reg [191:0] title=0;reg [127:0] difficulty=0;
    rhythm_game_renderer #(.BLOCK_GEOMETRY(1),.STREAM_METADATA(1),.BLOCK_HUD(1)) renderer(.metadata_valid(1'b1),.metadata_data(meta_data),.metadata_address(meta_address),.clk(clk),.rst(rst),.enabled(enabled),.de(de),.vs(vs),.song_time(song_time),.song_frames(song_frames),
        .state(state),.error_code(4'd7),.auto_mode(1'b1),.score(20'd1000000),.combo(16'd413),.max_combo(16'd413),
        .perfect_count(16'd413),.good_count(16'd0),.bad_count(16'd0),.miss_count(16'd0),.title(title),.difficulty(difficulty),
        .view_index(vi),.view_valid(vv),.view_start(start),.view_end(finish),.holding_mask(4'd0),.capture_busy(capture),
        .frame_enabled(frame_active),.pixel_on(on),.pixel_rgb(color));
    video_presentation #(.ENABLE_RHYTHM(1),.INITIAL_WARMUP_FRAMES(0)) presentation(
        .clk(clk),.rst(rst),.display_valid(display),.display_slot_async(3'd0),.display_switch_toggle_async(1'b0),.display_slot_applied_toggle(),.display_active(),
        .brightness_level_async(3'd4),.image_brightness_async(7'd50),.image_contrast_async(7'd50),.image_sharpness_async(7'd50),
        .image_selected_async(2'd0),.image_select_toggle_async(1'b0),.image_adjust_toggle_async(1'b0),
        .spectrum_bands(256'd0),.spectrum_bars(640'd0),.spectrum_radius(8'd100),
        .game_active(frame_active),.game_pixel_on(on),.game_pixel_rgb(color),.de(de),.vs(vs),.rgb_in(24'hc09060),.rgb_out(rgb));
    always @*begin
        vv=1;start=0;finish=0;
        case(vi)
            0:begin start=72000;finish=72000;end
            8:begin start=48000;finish=96000;end
            16:begin start=144000;finish=144000;end
            default:vv=0;
        endcase
    end
    reg [7:0] hud_written[0:255];reg [7:0] hud_expected;
    always @(posedge clk)begin
        if(renderer.hud.character_we)hud_written[renderer.hud.address]<=renderer.hud.character_write;
        hud_expected<=hud_written[renderer.hud.read_address];
    end
    always @(negedge clk)if(de && renderer.hud.character!==hud_expected)$fatal(1,"HUD RAM read latency");
    integer file_id,xx,yy,frame_number=0,pixels=0;
    reg [9:0] input_x=0,input_y=0,x1=0,y1=0,x2=0,y2=0;
    reg d1=0,d2=0,save=0;
    always @(posedge clk)begin d1<=de;d2<=d1;x1<=input_x;y1<=input_y;x2<=x1;y2<=y1;end
    always @(negedge clk)if(d2 && save)begin
        $fwrite(file_id,"%c%c%c",rgb[23:16],rgb[15:8],rgb[7:0]);pixels=pixels+1;
        if(x2==24 && y2==448 && rgb!==24'hffffff)$fatal(1,"title font first pixel/latency %h",rgb);
        if(x2==516 && y2==12 && rgb!==24'hffffff)$fatal(1,"score font first digit/latency %h",rgb);
        if(x2==136 && y2==304 && rgb!==24'h72dbff)$fatal(1,"Tap y/latency %h",rgb);
        if(x2==264 && y2==250 && rgb!==24'h276c9c && state!=10)$fatal(1,"Hold body %h",rgb);
        if(x2==400 && y2==384 && rgb!==24'hffffff)$fatal(1,"judge line %h",rgb);
        if(x2==500 && y2==300 && rgb!==(display ? 24'h302418 : 24'h000000))$fatal(1,"dim/fallback %h",rgb);
    end
    task frame;
        input integer number;
        begin @(negedge clk);vs=1;@(negedge clk);vs=0;repeat(4000)@(negedge clk);
            if(capture || renderer.work!=0)$fatal(1,"snapshot missed vertical blank");
            if(hud_written[0]!=8'h31 || hud_written[16]!=8'h30 || hud_written[18]!=8'h34 || hud_written[20]!=8'h33 || renderer.progress!=112 || hud_written[64]!=8'h42 || hud_written[96]!=8'h44)$fatal(1,"HUD conversion");
            file_id=$fopen(number==0 ? "prj/log/rhythm_stage4_regression/game.ppm" : (number==1 ? "prj/log/rhythm_stage4_regression/result.ppm" : "prj/log/rhythm_stage4_regression/fallback.ppm"),"wb");
            $fwrite(file_id,"P6\n640 480\n255\n");pixels=0;save=1;
            for(yy=0;yy<480;yy=yy+1)begin
                for(xx=0;xx<640;xx=xx+1)begin @(negedge clk);de=1;input_x=xx;input_y=yy;end
                @(negedge clk);de=0;repeat(160)@(negedge clk);
            end
            repeat(3)@(negedge clk);save=0;$fclose(file_id);if(pixels!=307200)$fatal(1,"pixel count %0d",pixels);
        end
    endtask
    task progress_case;
        input signed [32:0] time_value;input [31:0] frames_value;input [9:0] expected_progress;
        begin
            @(negedge clk);song_time=time_value;song_frames=frames_value;vs=1;
            @(negedge clk);vs=0;repeat(4000)@(negedge clk);
            if(capture || renderer.progress!=expected_progress)$fatal(1,"DSP progress high-word/negative boundary %0d",renderer.progress);
        end
    endtask
    initial begin
        title[87:0]="ENIHS EVARB";difficulty[103:0]="LAMRON S'LLED";
        for(xx=0;xx<24;xx=xx+1)meta_memory[xx]=title[xx*8 +:8];
        for(xx=0;xx<16;xx=xx+1)meta_memory[24+xx]=difficulty[xx*8 +:8];
        repeat(4)@(negedge clk);rst=0;repeat(10)@(negedge clk);frame(0);
        state=10;frame(1);
        rst=1;display=0;repeat(4)@(negedge clk);rst=0;repeat(10)@(negedge clk);frame(2);
        progress_case(33'sd1048576,32'd4194304,10'd112);
        progress_case(-33'sd96000,32'd4194304,10'd0);
        progress_case(33'sd2147483648,32'hffffffff,10'd224);
        $display("PASS renderer geometry, HUD, line masks, two-cycle RGB and black fallback");$finish;
    end
    initial begin #100000000;$fatal(1,"renderer timeout");end
endmodule
