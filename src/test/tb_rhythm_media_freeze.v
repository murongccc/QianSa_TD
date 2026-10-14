`timescale 1ns/1ps

module tb_rhythm_media_freeze;
reg clk = 1'b0;
reg rst = 1'b1;
reg key_next = 1'b1;
// SW2 is an active-high level enable in the board constraints.
reg key_auto = 1'b0;reg freeze=0;
reg scan_done = 1'b1;
reg candidate_valid = 1'b1;
reg [2:0] media_count = 3'd0;
reg loader_ready = 1'b1;
  reg frame_commit = 1'b0;
  reg load_abort = 1'b0;
reg display_switch_applied_toggle_async = 1'b0;
wire load_start;
wire [2:0] load_media_index;
wire [2:0] write_slot;
wire [2:0] display_slot;
wire display_switch_toggle;
wire display_valid;
wire auto_play_enabled;
wire load_inflight;

always #5 clk = ~clk;

media_session_controller #(
    .CLK_FREQ_HZ(1000),
    .AUTO_PERIOD_SECONDS(3),.ENABLE_FREEZE(1)
) dut (
    .freeze(freeze),.session_ready(),.game_auto_enable(1'b0),
    .clk(clk), .rst(rst), .key_next(key_next), .key_auto(key_auto),


    .scan_done(scan_done), .candidate_valid(candidate_valid), .media_count(media_count), .loader_ready(loader_ready),
      .frame_commit(frame_commit), .load_abort(load_abort),
    .display_switch_applied_toggle_async(display_switch_applied_toggle_async),
    .load_start(load_start),
    .load_media_index(load_media_index), .write_slot(write_slot),
    .display_slot(display_slot), .display_switch_toggle(display_switch_toggle), .display_valid(display_valid),
    .auto_play_enabled(auto_play_enabled), .load_inflight(load_inflight)
);

task press_next;
    begin
        @(negedge clk);key_next=0;repeat(30)@(negedge clk);
        key_next=1;repeat(30)@(negedge clk);
    end
endtask

task complete_load;
    input [2:0] expected_slot;
    begin
        wait (load_inflight);
        if (write_slot != expected_slot)
            $fatal(1, "loaded slot %0d, expected %0d", write_slot, expected_slot);
        @(negedge clk);
        frame_commit = 1'b1;
        @(negedge clk);
        frame_commit = 1'b0;
        media_count = expected_slot + 3'd1;
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

    // 首帧必须等待所有目录候选处理完成，不能在后续图片后台加载时显示。
    complete_load(3'd0);
    if (display_valid) $fatal(1, "display started before catalogue drain");

    // The other catalogue entries are background-preloaded into their fixed
    // slots.  No further SD load may occur when the user switches images.
    complete_load(3'd1);
    complete_load(3'd2);
    complete_load(3'd3);
    complete_load(3'd4);
    @(negedge clk);
    candidate_valid = 1'b0;
    repeat (4) @(posedge clk);
    if (load_inflight || dut.slot_ready != 5'b11111)
        $fatal(1, "background preload did not finish all five slots");
    apply_display;
    if (!display_valid) $fatal(1, "first picture was not committed after preload");

    // 冻结前一个切换在途，并保留待处理命令；在途必须完成，排队应被清空。
    press_next;press_next;wait(dut.display_switch_inflight);
    @(negedge clk);freeze=1;key_auto=1;key_next=0;
    apply_display;repeat(20)@(negedge clk);
    if(display_slot!=1 || !dut.session_ready || dut.manual_next_pending || dut.auto_next_pending || auto_play_enabled)
        $fatal(1,"freeze did not drain displayed/pending selection");
    press_next;repeat(4000)@(negedge clk);
    if(display_slot!=1 || dut.display_switch_inflight || dut.AUTO_PERIOD_CYCLES!=3000)$fatal(1,"game accepted picture KEY2/auto");
    @(negedge clk);freeze=0;key_auto=0;repeat(20)@(negedge clk);
    if(display_slot!=1 || dut.display_switch_inflight)$fatal(1,"held KEY2 replayed on exit");
    key_next=1;repeat(30)@(negedge clk);key_next=0;repeat(30)@(negedge clk);key_next=1;
    wait(dut.display_switch_inflight);apply_display;if(display_slot!=2)$fatal(1,"media KEY2 not restored");
    key_auto=1;repeat(3100)@(negedge clk);wait(dut.display_switch_inflight);apply_display;
    if(display_slot!=3)$fatal(1,"carousel not restored");
    $display("PASS media freeze, pending/inflight drain, KEY2 freeze, release arm, carousel restore");$finish;
end
initial begin #200000;$fatal(1,"freeze timeout");end
endmodule
