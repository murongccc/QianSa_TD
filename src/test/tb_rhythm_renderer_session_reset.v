`timescale 1ns/1ps
// 视频扫描不随游戏会话清理复位，覆盖真实低有效 VS 和帧中重开。
module tb_rhythm_renderer_session_reset;
    reg clk=0;always #20 clk=~clk;
    reg hard_reset=1,session_clear=0;
    wire hs,vs,de;
    color_bar timing(.clk(clk),.rst(hard_reset),.hs(hs),.vs(vs),.de(de),.rgb_r(),.rgb_g(),.rgb_b());
    wire frame_enabled,pixel_on,capture;wire [23:0] pixel_rgb;
    wire [9:0] observed_x=renderer.px,observed_y=renderer.y;
    rhythm_game_renderer #(.BLOCK_GEOMETRY(1),.STREAM_METADATA(1),.BLOCK_HUD(1)) renderer(
        .clk(clk),.rst(hard_reset || session_clear),.enabled(1'b1),.de(de),.vs(vs),
        .song_time(33'sd0),.song_frames(32'd10000),.state(4'd11),.error_code(4'd7),.auto_mode(1'b1),
        .score(20'd0),.combo(16'd0),.max_combo(16'd0),.perfect_count(16'd0),
        .good_count(16'd0),.bad_count(16'd0),.miss_count(16'd0),
        .metadata_valid(1'b0),.metadata_data(8'd0),.metadata_address(),.title(192'd0),.difficulty(128'd0),
        .view_index(),.view_valid(1'b0),.view_start(32'd0),.view_end(32'd0),.holding_mask(4'd0),
        .capture_busy(capture),.frame_enabled(frame_enabled),.pixel_on(pixel_on),.pixel_rgb(pixel_rgb));

    // 独立扫描参考只接受板级复位，游戏清理期间仍持续计数。
    reg ref_vs_d=0,ref_de_d=0;reg [9:0] ref_x=0,ref_y=0;
    integer real_frames=0;
    wire real_frame_start=vs && !ref_vs_d;
    wire [9:0] ref_px=de && !ref_de_d ? 10'd0 : ref_x;
    always @(posedge clk)begin
        if(hard_reset)begin ref_vs_d<=0;ref_de_d<=0;ref_x<=0;ref_y<=0;real_frames<=0;end
        else begin
            ref_vs_d<=vs;ref_de_d<=de;
            if(de && !ref_de_d)ref_x<=1;else if(de)ref_x<=ref_x+10'd1;
            if(!de && ref_de_d && ref_y<479)ref_y<=ref_y+10'd1;
            if(real_frame_start)begin ref_y<=0;real_frames<=real_frames+1;end
        end
    end
    wire [23:0] composed_rgb;
    video_presentation #(.ENABLE_RHYTHM(1),.INITIAL_WARMUP_FRAMES(0)) presentation(
        .clk(clk),.rst(hard_reset),.display_valid(1'b1),.display_slot_async(3'd0),.display_switch_toggle_async(1'b0),
        .display_slot_applied_toggle(),.display_active(),.brightness_level_async(3'd4),
        .image_brightness_async(7'd50),.image_contrast_async(7'd50),.image_sharpness_async(7'd50),
        .image_selected_async(2'd0),.image_select_toggle_async(1'b0),.image_adjust_toggle_async(1'b0),
        .spectrum_bands(256'd0),.spectrum_bars(640'd0),.spectrum_radius(8'd100),
        .spectrum_read_address(),.spectrum_read_data(8'd0),.spectrum_read_valid(1'b0),.spectrum_active(1'b0),
        // 与板级一致：会话保持有效，渲染器清理不切换背景。
        .game_active(1'b1),.game_pixel_on(pixel_on),.game_pixel_rgb(pixel_rgb),
        .de(de),.vs(vs),.rgb_in(24'hc09060),.rgb_out(composed_rgb));
    reg display_d1=0,display_d2=0;reg [9:0] display_x1=0,display_x2=0,display_y1=0,display_y2=0;
    always @(posedge clk)begin
        display_d1<=de;display_d2<=display_d1;display_x1<=ref_px;display_x2<=display_x1;display_y1<=ref_y;display_y2<=display_y1;
    end
    always @(negedge clk)if(!hard_reset && display_d2 && display_x2>=550 && display_y2>=100 && display_y2<409)
        if(composed_rgb!==24'h302418)$fatal(1,"background brightness changed during session clear: %h",composed_rgb);
    reg check_wait=0,check_coordinates=0;integer released_frame=0,checked_pixels=0;
    // 解除清理后、下一次真实 VS 边界前，不允许发布游戏像素或启动假快照。
    always @(negedge clk)if(!hard_reset && !session_clear)begin
        if(check_wait && real_frames==released_frame && !real_frame_start)begin
            if(frame_enabled || pixel_on || capture || renderer.hud.character_we)
                $fatal(1,"game UI published before true VS edge: physical=(%0d,%0d) renderer=(%0d,%0d)",ref_px,ref_y,observed_x,observed_y);
        end
        if(check_coordinates && de)begin
            checked_pixels=checked_pixels+1;
            if(observed_x!==ref_px || observed_y!==ref_y)
                $fatal(1,"raster mismatch after recovery physical=(%0d,%0d) renderer=(%0d,%0d)",ref_px,ref_y,observed_x,observed_y);
            if(!frame_enabled)$fatal(1,"game UI not restored on recovered frame");
        end
    end

    task clear_and_recover;
        input integer scenario;
        begin
            check_coordinates=0;
            @(negedge clk);session_clear=1;
            repeat(16)@(negedge clk);
            if(frame_enabled || pixel_on)$fatal(1,"game UI visible during clear");
            released_frame=real_frames;check_wait=1;session_clear=0;
            wait(real_frames>released_frame);
            // VS 边界后留足消隐时间，确认 HUD 和几何快照已完成。
            repeat(4000)@(negedge clk);
            check_wait=0;
            if(capture || renderer.hud.phase!=0)$fatal(1,"HUD/snapshot did not complete in vertical blank");
            check_coordinates=1;checked_pixels=0;
            wait(de && ref_y==479 && ref_px==639);
            wait(!de);
            @(negedge clk);check_coordinates=0;
            if(checked_pixels!=640*480)$fatal(1,"recovered frame pixel count %0d",checked_pixels);
            $display("PASS continuous-VS session reset scenario %0d, %0d aligned pixels",scenario,checked_pixels);
        end
    endtask
    initial begin
        repeat(5)@(negedge clk);hard_reset=0;
        wait(real_frames>=1);
        wait(de && ref_y==0 && ref_px==1);clear_and_recover(0);
        wait(de && ref_y==100 && ref_px==320);clear_and_recover(1);
        wait(de && ref_y==280 && ref_px==320);clear_and_recover(2);
        wait(de && ref_y==479 && ref_px==620);clear_and_recover(3);
        wait(!de && vs && ref_y==150 && timing.h_cnt==20);clear_and_recover(4);
        wait(!de && vs && timing.v_cnt==3 && timing.h_cnt==400);clear_and_recover(5);
        wait(!vs && timing.v_cnt==10 && timing.h_cnt==400);clear_and_recover(6);
        wait(!de && vs && timing.v_cnt==20 && timing.h_cnt==400);clear_and_recover(7);
        // 清理跨越 VS 上升沿，释放时 VS 已高，必须等下一次完整同步周期。
        wait(!vs && timing.v_cnt==11 && timing.h_cnt==10);clear_and_recover(8);
        $display("PASS renderer session clear: active pixels, horizontal/vertical blank, low VS and masked VS edge");
        $finish;
    end
    initial begin #400000000;$fatal(1,"session reset regression timeout");end
endmodule
