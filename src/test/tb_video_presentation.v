`timescale 1ns/1ps

// 使用 64x480 时序检查参数 OSD、频谱及底部字幕移除后的图像输出。
module tb_video_presentation;
parameter integer REFERENCE_SPECTRUM=0;
reg clk = 1'b0;
reg rst = 1'b1;
reg display_valid = 1'b1;
reg [2:0] display_slot_async = 3'd0;
reg display_switch_toggle_async = 1'b0;
wire display_slot_applied_toggle;
wire display_active;
reg [2:0] brightness_level_async = 3'd4;
reg [6:0] image_brightness_async = 7'd50;
reg [6:0] image_contrast_async = 7'd50;
reg [6:0] image_sharpness_async = 7'd50;
reg [1:0] image_selected_async = 2'd0;
reg image_select_toggle_async = 1'b0;
reg image_adjust_toggle_async = 1'b0;
reg [255:0] spectrum_bands = 256'd0;
wire [639:0] spectrum_bars=(|spectrum_bands)?{80{8'd120}}:640'd0;
reg de = 1'b0;
reg vs = 1'b0;
reg [23:0] rgb_in = 24'h808080;
wire [23:0] rgb_out;
integer line;
integer pixel;
integer osd_text_pixels;
integer control_level;
integer ring_overlay_pixels=0;
reg [23:0] expected_ring_rgb;
reg [7:0] previous_control_value;

always #20 clk = ~clk;

video_presentation #(
    .REFERENCE_SPECTRUM(REFERENCE_SPECTRUM),
    .ACTIVE_WIDTH(64), .ACTIVE_HEIGHT(480), .OSD_DISPLAY_CYCLES(5000),
    .INITIAL_WARMUP_FRAMES(0)
) dut (.spectrum_read_address(),.spectrum_read_data(8'd0),.spectrum_read_valid(1'b0),.spectrum_active(1'b0),
    .game_active(1'b0),.game_pixel_on(1'b0),.game_pixel_rgb(24'd0),
    .clk(clk), .rst(rst), .display_valid(display_valid),
    .display_slot_async(display_slot_async),
    .display_switch_toggle_async(display_switch_toggle_async),
    .display_slot_applied_toggle(display_slot_applied_toggle),
    .display_active(display_active),
    .brightness_level_async(brightness_level_async),
    .de(de), .vs(vs),
    .image_brightness_async(image_brightness_async),
    .image_contrast_async(image_contrast_async),
    .image_sharpness_async(image_sharpness_async),
    .image_selected_async(image_selected_async),
    .image_select_toggle_async(image_select_toggle_async),
    .image_adjust_toggle_async(image_adjust_toggle_async),
    .spectrum_bands(spectrum_bands),
    .spectrum_bars(spectrum_bars),
    .spectrum_radius(8'd90),
    .rgb_in(rgb_in), .rgb_out(rgb_out)
);

// 频谱内部第一级必须与视频其他第一级信号对齐，不能多延迟一拍。
always @(posedge clk) begin
    if (!rst && dut.base_valid_stage && !dut.param_osd_stage && dut.spectrum_on) begin
        expected_ring_rgb=dut.spectrum_rgb;
        #1;
        if (rgb_out!==expected_ring_rgb) $fatal(1,"ring overlay latency/color mismatch");
        ring_overlay_pixels=ring_overlay_pixels+1;
    end
end

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
            // 原字幕区域应输出原图；跳过行首流水填充拍，并在静音帧检查。
            if ((y >= 428) && (y < 462) && (pixel >= 2) &&
                (spectrum_bands == 256'd0) && (rgb_out !== rgb_in))
                $fatal(1, "removed subtitle area changed background at y=%0d x=%0d", y, pixel);
        end
        @(negedge clk); de = 1'b0;
    end
endtask

initial begin
    repeat (3) @(posedge clk);
    rst = 1'b0;
    // display_valid 经过两级同步后，首个帧边界才允许 display_active 置位。
    repeat (3) @(posedge clk);
    next_frame;
    for (line = 0; line < 480; line = line + 1)
        active_line(line);

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

    // 两拍真实像素路径在兼容锐度输入为 100 时仍应逐像素输出原图。
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
    if (rgb_out != 24'h808080)
        $fatal(1, "removed sharpness changed pixel: %h", rgb_out);
    @(negedge clk); de = 1'b0;

    spectrum_bands={32{8'd255}};
    next_frame;
    for (line=0;line<480;line=line+1) active_line(line);
    if (ring_overlay_pixels<20) $fatal(1,"ring overlay not exercised");
    spectrum_bands=0;
    $display("PASS video presentation: OSD, timeout, adjustment, removed sharpness, and overlays");
    $finish;
end
endmodule
