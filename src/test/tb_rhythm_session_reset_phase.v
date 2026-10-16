`timescale 1ns/1ps
// 复位只允许在下降沿随会话变化；全局复位在停钟时仍必须异步断言。
module tb_rhythm_session_reset_phase;
reg clk=0,clock_enabled=1,rst=1,sw1=1;
always #20 if(clock_enabled)clk=~clk;
wire er,clear;
wire [3:0] state;
integer clear_cycles=0,clears=0;
rhythm_session_controller #(.CLOCK_HZ(48000),.DEBOUNCE_MS(1),.PREROLL_SAMPLES(8)) dut(
    .clk(clk),.rst(rst),.game_switch(1'b1),.run_switch(sw1),
    .restart_key_n(1'b1),.pause_key_n(1'b1),.mode_key_n(1'b1),
    .media_quiet_async(1'b1),.resources_ready_async(1'b1),.cancelled_async(1'b1),
    .audio_eof_async(1'b0),.chart_eof_async(1'b0),.error_async(4'd0),
    .frames_async(32'd10000),.fifo_level_async(32'd4096),.notes_async(16'd1),.offset_async(32'sd0),
    .sample_emitted(1'b0),.sample_missing(1'b0),.prefetch_ready(1'b1),
    .sample_index(32'd0),.emitted_count(32'd0),.judge_done(1'b0),.queue_overflow(1'b0),
    .freeze_media(),.active_game(),.auto_mode(),.resource_reset(clear),.resource_enable(),.resource_cancel(),
    .engine_reset(er),.engine_run(),.engine_load(),.player_mode(),.song_time(),.song_frames(),
    .total_notes(),.chart_offset(),.chart_eof(),.state(state),.error_code());
always @(er or clear)if(!rst && $time>1 && clk!==1'b0)
    $fatal(1,"session reset changed outside falling phase");
always @(posedge clear)clear_cycles=0;
always @(posedge clk)if(clear && !rst)clear_cycles=clear_cycles+1;
always @(negedge clear)if(!rst && $time>1)begin
    if(clear_cycles!=16)$fatal(1,"resource reset length %0d",clear_cycles);
    clears=clears+1;
end
task wait_state;
    input [3:0] expected;
    integer n;
    begin
        n=0;
        while(state!=expected && n<2000)begin @(negedge clk);#1;n=n+1;end
        if(state!=expected)$fatal(1,"phase test state timeout %0d/%0d",state,expected);
    end
endtask
initial begin
    #1;if(!er || clear)$fatal(1,"global reset initial values");
    repeat(5)@(negedge clk);#1;rst=0;
    wait_state(6);if(er || clear)$fatal(1,"active game stayed reset");
    @(posedge clk);#1;clock_enabled=0;
    #2;rst=1;#1;if(!er || clear)$fatal(1,"stopped-clock async reset failed");
    #100;rst=0;#100;if(!er)$fatal(1,"reset released without falling edge");
    clock_enabled=1;wait_state(6);
    sw1=0;wait_state(2);#1;if(!er)$fatal(1,"intentional stop did not reset engine");
    sw1=1;wait_state(6);if(er || clear || clears<3)$fatal(1,"restart phase/clear coverage");
    $display("PASS session reset falling phase, full 16-cycle resource clear, stopped-clock asynchronous global reset, stop/restart");$finish;
end
initial begin #1000000;$fatal(1,"reset phase timeout");end
endmodule
