`timescale 1ns/1ps
// 游戏进入/退出只在真实帧边界改变背景，帧中会话变化不能形成亮度分区。
module tb_rhythm_background_mode;
    reg clk=0,rst=1,de=0,vs=0,game=0;always #20 clk=~clk;
    wire [23:0] rgb;
    video_presentation #(.ENABLE_RHYTHM(1),.INITIAL_WARMUP_FRAMES(0),.ACTIVE_WIDTH(64),.ACTIVE_HEIGHT(32)) dut(
        .game_pixel_light(1'b0),.touch_frame_packet(40'd0),
        .clk(clk),.rst(rst),.display_valid(1'b1),.info_frame_start(),.info_slot(),.display_info(89'd0),.display_slot_async(3'd0),.display_switch_toggle_async(1'b0),
        .display_slot_applied_toggle(),.display_active(),
        .image_brightness_async(7'd50),.image_contrast_async(7'd50),.image_sharpness_async(7'd50),
        .image_selected_async(2'd0),
        .spectrum_bands(256'd0),.spectrum_bars(640'd0),.spectrum_radius(8'd100),
        .spectrum_read_address(),.spectrum_read_data(8'd0),.spectrum_read_valid(1'b0),.spectrum_active(1'b0),
        .game_active(game),.game_pixel_on(1'b0),.game_pixel_rgb(24'd0),.de(de),.vs(vs),.rgb_in(24'hc09060),.rgb_out(rgb));
    task boundary;
        begin @(negedge clk);de=0;vs=1;@(negedge clk);vs=0;repeat(5)@(negedge clk);end
    endtask
    task check_pixels;
        input [23:0] expected;integer i;
        begin
            @(negedge clk);de=1;repeat(3)@(negedge clk);
            for(i=0;i<16;i=i+1)begin @(negedge clk);if(rgb!==expected)$fatal(1,"background mode got %h expected %h",rgb,expected);end
            de=0;repeat(5)@(negedge clk);
        end
    endtask
    initial begin
        repeat(4)@(negedge clk);rst=0;repeat(10)@(negedge clk);
        boundary;check_pixels(24'hc09060);
        game=1;check_pixels(24'hc09060);boundary;check_pixels(24'h3c2d1e);
        // 清理渲染器时会话维持game=1；连续多次帧中检查不得亮起。
        check_pixels(24'h3c2d1e);check_pixels(24'h3c2d1e);
        game=0;check_pixels(24'h3c2d1e);boundary;check_pixels(24'hc09060);
        $display("PASS background mode: frame-boundary enter/exit and stable dimming during clear");$finish;
    end
    initial begin #100000;$fatal(1,"background mode timeout");end
endmodule
