`timescale 1ns/1ps

module tb_media_session_controller;
reg clk = 1'b0;
reg rst = 1'b1;
reg key_next = 1'b1;
reg key_auto = 1'b1;
reg [2:0] uart_command_async = 3'd0;
reg uart_command_toggle_async = 1'b0;
reg scan_done = 1'b1;
reg [2:0] media_count = 3'd4;
reg loader_ready = 1'b1;
reg frame_commit = 1'b0;
wire load_start;
wire [1:0] load_media_index;
wire [1:0] write_slot;
wire [1:0] display_slot;
wire display_valid;
wire auto_play_enabled;
wire load_inflight;

always #5 clk = ~clk;

media_session_controller #(
    .CLK_FREQ_HZ(100),
    .AUTO_PERIOD_SECONDS(3)
) dut (
    .clk(clk), .rst(rst), .key_next(key_next), .key_auto(key_auto),
    .uart_command_async(uart_command_async),
    .uart_command_toggle_async(uart_command_toggle_async),
    .scan_done(scan_done), .media_count(media_count), .loader_ready(loader_ready),
    .frame_commit(frame_commit), .load_start(load_start),
    .load_media_index(load_media_index), .write_slot(write_slot),
    .display_slot(display_slot), .display_valid(display_valid),
    .auto_play_enabled(auto_play_enabled), .load_inflight(load_inflight)
);

task uart_command;
    input [2:0] command;
    begin
        @(negedge clk);
        uart_command_async = command;
        uart_command_toggle_async = ~uart_command_toggle_async;
        repeat (4) @(posedge clk);
    end
endtask

task complete_load;
    begin
        wait (load_inflight);
        @(negedge clk);
        frame_commit = 1'b1;
        @(negedge clk);
        frame_commit = 1'b0;
        repeat (2) @(posedge clk);
    end
endtask

initial begin
    repeat (3) @(posedge clk);
    rst = 1'b0;

    // First picture becomes visible.
    complete_load;
    if (!display_valid) $fatal(1, "first picture was not committed");

    // N queues and starts one manual picture change.
    uart_command(3'd1);
    wait (load_inflight);
    if (load_media_index != 2'd1) $fatal(1, "N did not select the next picture");
    complete_load;

    // 1 configures one second (100 cycles in this reduced-rate test).
    uart_command(3'd3);
    if (dut.auto_period_cycles != 32'd100) $fatal(1, "1 did not select one second");

    // A enables carousel mode.
    uart_command(3'd2);
    if (!auto_play_enabled) $fatal(1, "A did not enable auto-play");

    // Let the interval expire; an automatic load must start.
    repeat (105) @(posedge clk);
    if (!load_inflight) $fatal(1, "auto-play interval did not start a load");
    complete_load;
    $display("PASS: UART next, mode, and period commands");
    $finish;
end
endmodule
