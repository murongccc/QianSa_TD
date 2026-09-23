`timescale 1ns/1ps

// 首图必须在完整视频帧预热结束后才显示；之后切图不得重新触发等待。
module tb_video_presentation_startup;
reg clk=0, rst=1, display_valid=0, display_switch_toggle_async=0;
reg [2:0] display_slot_async=0;
reg [2:0] brightness_level_async=3'd4;
reg [6:0] image_brightness_async=7'd50, image_contrast_async=7'd50, image_sharpness_async=7'd50;
reg [1:0] image_selected_async=0;
reg image_select_toggle_async=0, image_adjust_toggle_async=0;
reg [255:0] spectrum_bands=0;
reg de=0, vs=0;
reg [23:0] rgb_in=24'h406080;
wire display_slot_applied_toggle, display_active;
wire [23:0] rgb_out;

always #5 clk=~clk;

video_presentation #(
    .ACTIVE_WIDTH(4), .ACTIVE_HEIGHT(4), .OSD_DISPLAY_CYCLES(16),
    .INITIAL_WARMUP_FRAMES(3)
) dut (
    .clk(clk), .rst(rst), .display_valid(display_valid),
    .display_slot_async(display_slot_async),
    .display_switch_toggle_async(display_switch_toggle_async),
    .display_slot_applied_toggle(display_slot_applied_toggle),
    .display_active(display_active),
    .brightness_level_async(brightness_level_async),
    .image_brightness_async(image_brightness_async), .image_contrast_async(image_contrast_async),
    .image_sharpness_async(image_sharpness_async), .image_selected_async(image_selected_async),
    .image_select_toggle_async(image_select_toggle_async), .image_adjust_toggle_async(image_adjust_toggle_async),
    .spectrum_bands(spectrum_bands), .de(de), .vs(vs), .rgb_in(rgb_in), .rgb_out(rgb_out)
);

task frame_start;
    begin
        @(negedge clk); vs=1'b1;
        @(negedge clk); vs=1'b0;
        @(posedge clk);
    end
endtask

initial begin
    repeat(3) @(posedge clk);
    rst=0;
    display_valid=1;
    repeat(3) @(posedge clk); // 等待两级跨域同步

    frame_start; if (display_active) $fatal(1,"startup display opened on warm-up frame 1");
    frame_start; if (display_active) $fatal(1,"startup display opened on warm-up frame 2");
    frame_start; if (display_active) $fatal(1,"startup display opened on warm-up frame 3");
    frame_start; if (!display_active) $fatal(1,"startup display did not open on the boundary after warm-up");

    display_slot_async=3'd1;
    display_switch_toggle_async=~display_switch_toggle_async;
    repeat(3) @(posedge clk);
    frame_start;
    if (!display_active) $fatal(1,"runtime slot switch incorrectly re-armed warm-up");

    $display("PASS video presentation startup: frame-boundary warm-up and runtime switch");
    $finish;
end

initial begin
    #100000;
    $fatal(1,"video presentation startup timeout");
end
endmodule
