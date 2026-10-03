`timescale 1ns/1ps

module tb_rhythm_image_guard;
reg clk = 1'b0;
reg rst = 1'b1;reg freeze=0;
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
reg select_toggle_before;

always #5 clk = ~clk;

image_controls #(.CLK_FREQ_HZ(1000), .DEBOUNCE_MS(2),.ENABLE_GAME_GUARD(1)) dut (
    .freeze(freeze),
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

    freeze=1;key_inc_n=0;repeat(10)@(negedge clk);
    if(brightness!=50 || contrast!=50)$fatal(1,"game modified image parameter");
    freeze=0;repeat(10)@(negedge clk);if(brightness!=50)$fatal(1,"held KEY3 replayed on exit");
    key_inc_n=1;repeat(10)@(negedge clk);press_inc;if(brightness!=55)$fatal(1,"parameter input not restored");
    freeze=1;press_dec;if(brightness!=55)$fatal(1,"game KEY4 changed parameter");freeze=0;
    $display("PASS game image parameter gate and release arm");$finish;
end
endmodule
