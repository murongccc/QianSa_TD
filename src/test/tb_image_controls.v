`timescale 1ns/1ps

module tb_image_controls;
reg clk = 1'b0;
reg rst = 1'b1;
reg key_inc_n = 1'b1;
reg key_dec_n = 1'b1;
reg sw_sel_b = 1'b0;
reg sw_sel_a = 1'b0;
wire [6:0] brightness;
wire [6:0] contrast;
wire [6:0] sharpness;
wire [1:0] selected;
wire select_toggle;
wire adjust_toggle;
integer index;

always #5 clk = ~clk;

image_controls #(.CLK_FREQ_HZ(1000), .DEBOUNCE_MS(2)) dut (
    .clk(clk), .rst(rst),
    .key_inc_n(key_inc_n), .key_dec_n(key_dec_n),
    .sw_sel_b(sw_sel_b), .sw_sel_a(sw_sel_a),
    .brightness(brightness), .contrast(contrast), .sharpness(sharpness),
    .selected(selected), .select_toggle(select_toggle),
    .adjust_toggle(adjust_toggle)
);

task settle_switch;
    input [1:0] value;
    begin
        {sw_sel_b,sw_sel_a} = value;
        repeat (5) @(posedge clk);
    end
endtask

task press_inc;
    begin
        @(negedge clk); key_inc_n = 1'b0;
        repeat (5) @(posedge clk);
        @(negedge clk); key_inc_n = 1'b1;
        repeat (5) @(posedge clk);
    end
endtask

task press_dec;
    begin
        @(negedge clk); key_dec_n = 1'b0;
        repeat (5) @(posedge clk);
        @(negedge clk); key_dec_n = 1'b1;
        repeat (5) @(posedge clk);
    end
endtask

initial begin
    repeat (3) @(posedge clk);
    rst = 1'b0;
    repeat (3) @(posedge clk);
    if (brightness != 7'd50 || contrast != 7'd50 || sharpness != 7'd50 || selected != 2'd0)
        $fatal(1, "reset defaults failed");

    press_inc;
    if (brightness != 7'd55)
        $fatal(1, "brightness increment failed");
    press_dec;
    if (brightness != 7'd50)
        $fatal(1, "brightness decrement failed");

    settle_switch(2'b01);
    if (selected != 2'd1) $fatal(1, "contrast selection failed");
    press_inc;
    if (contrast != 7'd55) $fatal(1, "contrast increment failed");

    settle_switch(2'b10);
    if (selected != 2'd2) $fatal(1, "sharpness selection failed");
    for (index = 0; index < 12; index = index + 1) press_inc;
    if (sharpness != 7'd100) $fatal(1, "upper saturation failed: %0d", sharpness);
    for (index = 0; index < 22; index = index + 1) press_dec;
    if (sharpness != 7'd0) $fatal(1, "lower saturation failed: %0d", sharpness);

    settle_switch(2'b11);
    if (selected != 2'd2) $fatal(1, "reserved switch combination changed selection");
    press_inc;
    if (sharpness != 7'd5) $fatal(1, "reserved switch did not retain selected parameter");

    $display("PASS image_controls: debounce, selection, steps, saturation, and reserved switch");
    $finish;
end
endmodule
