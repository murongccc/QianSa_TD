`timescale 1ns/1ps

module tb_media_session_controller;
reg clk = 1'b0;
reg rst = 1'b1;
reg key_next = 1'b1;
// SW2 is an active-high level enable in the board constraints.
reg key_auto = 1'b0;
reg [2:0] uart_command_async = 3'd0;
reg uart_command_toggle_async = 1'b0;
reg scan_done = 1'b1;
reg [2:0] media_count = 3'd4;
reg loader_ready = 1'b1;
  reg frame_commit = 1'b0;
  reg load_abort = 1'b0;
reg display_switch_applied_toggle_async = 1'b0;
wire load_start;
wire [1:0] load_media_index;
wire [1:0] write_slot;
wire [1:0] display_slot;
wire display_switch_toggle;
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
      .frame_commit(frame_commit), .load_abort(load_abort),
    .display_switch_applied_toggle_async(display_switch_applied_toggle_async),
    .load_start(load_start),
    .load_media_index(load_media_index), .write_slot(write_slot),
    .display_slot(display_slot), .display_switch_toggle(display_switch_toggle), .display_valid(display_valid),
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
    input [1:0] expected_slot;
    begin
        wait (load_inflight);
        if (write_slot != expected_slot)
            $fatal(1, "loaded slot %0d, expected %0d", write_slot, expected_slot);
        @(negedge clk);
        frame_commit = 1'b1;
        @(negedge clk);
        frame_commit = 1'b0;
        repeat (2) @(posedge clk);
    end
endtask

task apply_display;
    begin
        wait (dut.display_switch_inflight);
        @(negedge clk);
        display_switch_applied_toggle_async = ~display_switch_applied_toggle_async;
        repeat (4) @(posedge clk);
    end
endtask

initial begin
    repeat (3) @(posedge clk);
    rst = 1'b0;

    // First picture is loaded, then becomes visible only after the video
    // domain applies the requested slot on a frame boundary.
    complete_load(2'd0);
    apply_display;
    if (!display_valid) $fatal(1, "first picture was not committed");

    // The other catalogue entries are background-preloaded into their fixed
    // slots.  No further SD load may occur when the user switches images.
    complete_load(2'd1);
    complete_load(2'd2);
    repeat (4) @(posedge clk);
    if (load_inflight || dut.slot_ready != 3'b111)
        $fatal(1, "background preload did not finish all three slots");

    // Queue three manual changes before the first acknowledgement.  They
    // must be presented in sequence rather than collapsed by the video CDC.
    uart_command(3'd1);
    uart_command(3'd1);
    uart_command(3'd1);
    wait (dut.display_switch_inflight);
    if (display_slot != 2'd1) $fatal(1, "first queued switch did not select slot 1");
    apply_display;
    wait (dut.display_switch_inflight);
    if (display_slot != 2'd2) $fatal(1, "second queued switch did not select slot 2");
    apply_display;
    wait (dut.display_switch_inflight);
    if (display_slot != 2'd0) $fatal(1, "third queued switch did not wrap to slot 0");
    apply_display;
    if (load_inflight) $fatal(1, "a ready-slot switch unexpectedly reloaded SD data");

    // 1 configures one second (100 cycles in this reduced-rate test).
    uart_command(3'd3);
    if (dut.auto_period_cycles != 32'd100) $fatal(1, "1 did not select one second");

    // SW2 enables carousel mode directly; UART A is retained only for
    // backwards-compatible command decoding and must not override the switch.
    key_auto = 1'b1;
    repeat (3) @(posedge clk);
    @(negedge clk);
    if (!auto_play_enabled) $fatal(1, "SW2 did not enable auto-play");

    // Let the interval expire; an automatic load must start.
    repeat (105) @(posedge clk);
    if (!dut.display_switch_inflight) $fatal(1, "auto-play interval did not request a displayed switch");
    apply_display;
    $display("PASS: preload, frame-boundary display queue, UART mode, and period commands");
    $finish;
end
endmodule
