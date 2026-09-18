`timescale 1ns/1ps

// Self-checks the OSD pixel priority using a compact 64x480 timing model.
// The subtitle coordinates retain their production y positions, while the
// smaller width makes the test quick and sufficient for the overlay logic.
module tb_video_presentation;
reg clk = 1'b0;
reg rst = 1'b1;
reg display_valid = 1'b1;
reg [1:0] display_slot_async = 2'd0;
reg display_switch_toggle_async = 1'b0;
wire display_slot_applied_toggle;
reg [2:0] brightness_level_async = 3'd4;
reg [6:0] image_brightness_async = 7'd50;
reg [6:0] image_contrast_async = 7'd50;
reg [6:0] image_sharpness_async = 7'd50;
reg [1:0] image_selected_async = 2'd0;
reg image_select_toggle_async = 1'b0;
reg image_adjust_toggle_async = 1'b0;
reg [63:0] spectrum_bands = 64'd0;
reg de = 1'b0;
reg vs = 1'b0;
reg [23:0] rgb_in = 24'h808080;
wire [23:0] rgb_out;
integer line;
integer pixel;
integer osd_text_pixels;
integer control_level;
reg [7:0] previous_control_value;

always #20 clk = ~clk;

video_presentation #(
    .ACTIVE_WIDTH(64), .ACTIVE_HEIGHT(480), .OSD_DISPLAY_CYCLES(5000)
) dut (
    .clk(clk), .rst(rst), .display_valid(display_valid),
    .display_slot_async(display_slot_async),
    .display_switch_toggle_async(display_switch_toggle_async),
    .display_slot_applied_toggle(display_slot_applied_toggle),
    .brightness_level_async(brightness_level_async),
    .de(de), .vs(vs),
    .image_brightness_async(image_brightness_async),
    .image_contrast_async(image_contrast_async),
    .image_sharpness_async(image_sharpness_async),
    .image_selected_async(image_selected_async),
    .image_select_toggle_async(image_select_toggle_async),
    .image_adjust_toggle_async(image_adjust_toggle_async),
    .spectrum_bands(spectrum_bands),
    .rgb_in(rgb_in), .rgb_out(rgb_out)
);

task next_frame;
    begin
        @(negedge clk); vs = 1'b1;
        @(negedge clk); vs = 1'b0;
    end
endtask

task active_line;
    input integer y;
    begin
        @(negedge clk); de = 1'b1;
        for (pixel = 0; pixel < 64; pixel = pixel + 1) begin
            @(posedge clk);
            #1;
            if (y == 438 && pixel == 3 && rgb_out != 24'hFFE040)
                $fatal(1, "subtitle glyph did not have highest priority");
            if (y == 430 && pixel == 33 && rgb_out == rgb_in)
                $fatal(1, "subtitle banner did not alpha blend the background");
        end
        @(negedge clk); de = 1'b0;
    end
endtask

initial begin
    repeat (3) @(posedge clk);
    rst = 1'b0;
    next_frame;
    for (line = 0; line < 480; line = line + 1)
        active_line(line);
    if (dut.subtitle_scroll_x != 9'd0)
        $fatal(1, "subtitle moved before its configured tick period");

    // 单独验证有符号边缘增强：50 完全旁路，高档分别加入
    // 水平差分的 1/4 和 1/2，并对超出 8 bit 的结果饱和。
    if (dut.sharpen_component(8'd128, 8'd64, 7'd50) != 8'd128)
        $fatal(1, "neutral sharpness is not a bypass");
    if (dut.sharpen_component(8'd128, 8'd64, 7'd75) != 8'd144)
        $fatal(1, "light edge enhancement failed");
    if (dut.sharpen_component(8'd128, 8'd64, 7'd100) != 8'd160)
        $fatal(1, "strong edge enhancement failed");
    if (dut.sharpen_component(8'd240, 8'd0, 7'd100) != 8'hff ||
        dut.sharpen_component(8'd8, 8'd240, 7'd100) != 8'd0)
        $fatal(1, "sharpness saturation failed");
    if (dut.sharpen_component(8'd96, 8'd96, 7'd100) != 8'd96)
        $fatal(1, "flat region changed by sharpness");

    // Every legal five-point control value must alter a non-saturated pixel.
    previous_control_value = 8'd0;
    for (control_level = 0; control_level <= 100; control_level = control_level + 5) begin
        if (control_level != 0 &&
            dut.image_adjust_component(8'd160, 7'd50, control_level) <= previous_control_value)
            $fatal(1, "contrast plateau at level %0d", control_level);
        previous_control_value = dut.image_adjust_component(8'd160, 7'd50, control_level);
    end
    if (dut.image_adjust_component(8'd160, 7'd50, 7'd0) != 8'd144 ||
        dut.image_adjust_component(8'd160, 7'd50, 7'd50) != 8'd160 ||
        dut.image_adjust_component(8'd160, 7'd50, 7'd100) != 8'd192)
        $fatal(1, "contrast endpoint curve failed");
    previous_control_value = 8'd0;
    for (control_level = 0; control_level <= 100; control_level = control_level + 5) begin
        if (control_level != 0 &&
            dut.sharpen_component(8'd192, 8'd64, control_level) <= previous_control_value)
            $fatal(1, "sharpness plateau at level %0d", control_level);
        previous_control_value = dut.sharpen_component(8'd192, 8'd64, control_level);
    end
    if (dut.sharpen_component(8'd192, 8'd64, 7'd0) != 8'd128 ||
        dut.sharpen_component(8'd192, 8'd64, 7'd50) != 8'd192 ||
        dut.sharpen_component(8'd192, 8'd64, 7'd100) != 8'hff)
        $fatal(1, "sharpness endpoint curve failed");

    // Selecting brightness must show its name, without restoring the old
    // two-row block meter.  The toggle crosses two synchronizer stages.
    image_select_toggle_async = ~image_select_toggle_async;
    repeat (4) @(posedge clk);
    osd_text_pixels = 0;
    next_frame;
    for (line = 0; line < 55; line = line + 1) begin
        @(negedge clk); de = 1'b1;
        for (pixel = 0; pixel < 64; pixel = pixel + 1) begin
            @(posedge clk);
            #1;
            if ((line >= 2) && (line < 10) && (rgb_out == 24'h000000))
                osd_text_pixels = osd_text_pixels + 1;
            // 显示路径为两级寄存，仿真行首的两个填充拍不属于画面。
            if ((line >= 16) && (line < 54) && (pixel >= 2) &&
                (rgb_out != 24'h808080))
                $fatal(1, "legacy block-meter OSD is still visible");
        end
        @(negedge clk); de = 1'b0;
    end
    if (osd_text_pixels == 0)
        $fatal(1, "BRIGHTNESS parameter OSD is not visible");
    if (dut.parameter_osd_char(5'd0) != "B" ||
        dut.parameter_osd_char(5'd9) != "S" ||
        dut.parameter_osd_char(5'd10) != " " ||
        dut.parameter_osd_char(5'd16) != " ")
        $fatal(1, "parameter OSD contains a suffix after BRIGHTNESS");

    image_selected_async = 2'd1;
    image_select_toggle_async = ~image_select_toggle_async;
    repeat (4) @(posedge clk);
    if (dut.parameter_osd_char(5'd0) != "C" || dut.parameter_osd_char(5'd7) != "T" ||
        dut.parameter_osd_char(5'd8) != " ")
        $fatal(1, "CONTRAST parameter OSD failed");
    image_selected_async = 2'd2;
    image_select_toggle_async = ~image_select_toggle_async;
    repeat (4) @(posedge clk);
    if (dut.parameter_osd_char(5'd0) != "S" || dut.parameter_osd_char(5'd8) != "S" ||
        dut.parameter_osd_char(5'd9) != " ")
        $fatal(1, "SHARPNESS parameter OSD failed");

    // Adjustment mode must contain only the compact numeric value.
    image_selected_async = 2'd0;
    image_brightness_async = 7'd50;
    image_adjust_toggle_async = ~image_adjust_toggle_async;
    repeat (4) @(posedge clk);
    if (dut.parameter_osd_char(5'd0) != "5" ||
        dut.parameter_osd_char(5'd1) != "0" ||
        dut.parameter_osd_char(5'd2) != " ")
        $fatal(1, "adjustment OSD contains text or trailing boxes");

    image_brightness_async = 7'd5;
    repeat (3) @(posedge clk);
    image_adjust_toggle_async = ~image_adjust_toggle_async;
    repeat (4) @(posedge clk);
    if (dut.parameter_osd_char(5'd0) != "5" ||
        dut.parameter_osd_char(5'd1) != " ")
        $fatal(1, "one-digit parameter OSD failed");

    image_brightness_async = 7'd100;
    repeat (3) @(posedge clk);
    image_adjust_toggle_async = ~image_adjust_toggle_async;
    repeat (4) @(posedge clk);
    if (dut.parameter_osd_char(5'd0) != "1" ||
        dut.parameter_osd_char(5'd1) != "0" ||
        dut.parameter_osd_char(5'd2) != "0" ||
        dut.parameter_osd_char(5'd3) != " ")
        $fatal(1, "three-digit parameter OSD failed");

    // 无新事件时，计数到期必须自动隐藏参数提示。
    repeat (5001) @(posedge clk);
    #1;
    if (dut.show_osd !== 1'b0)
        $fatal(1, "parameter OSD timeout failed");

    // A non-neutral brightness value must affect the underlying video.
    image_brightness_async = 7'd75;
    repeat (4) @(posedge clk);
    next_frame;
    @(negedge clk); de = 1'b1;
    repeat (25) @(posedge clk);
    if (rgb_out == 24'h808080)
        $fatal(1, "image brightness adjustment did not affect video");
    @(negedge clk); de = 1'b0;

    if (dut.image_adjust_component(8'd128, 7'd50, 7'd50) != 8'd128 ||
        dut.image_adjust_component(8'd255, 7'd100, 7'd100) != 8'hff ||
        dut.image_adjust_component(8'd0, 7'd0, 7'd100) != 8'd0)
        $fatal(1, "brightness/contrast neutral or saturation behavior failed");

    // 验证真实寄存像素路径：行首像素必须旁路已清零的上一行邻域，
    // 第二像素使用第一像素作为左邻域，并加入 1/2 差分。
    image_brightness_async = 7'd50;
    image_contrast_async = 7'd50;
    image_sharpness_async = 7'd100;
    repeat (4) @(posedge clk);
    @(negedge clk); de = 1'b0;
    repeat (2) @(posedge clk);
    @(negedge clk); de = 1'b1; rgb_in = 24'h404040;
    @(posedge clk); #1;
    @(negedge clk); rgb_in = 24'h808080;
    @(posedge clk); #1;
    if (rgb_out != 24'h404040)
        $fatal(1, "line-first pixel used a previous-line neighbour: %h", rgb_out);
    @(negedge clk); rgb_in = 24'h808080;
    @(posedge clk); #1;
    if (rgb_out != 24'hA0A0A0)
        $fatal(1, "registered horizontal edge enhancement failed: %h", rgb_out);
    @(negedge clk); de = 1'b0;

    $display("PASS video presentation: OSD, timeout, adjustment, sharpness, and overlays");
    $finish;
end
endmodule
