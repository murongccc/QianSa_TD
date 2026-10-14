`timescale 1ns/1ps
module tb_pcm_audio_player;
  reg clk=0, rst=1, fifo_empty=1;
  reg [1:0] playback_mode=2'd1;
  reg [31:0] fifo_dout=32'h1234_5678;
  wire fifo_re, audio_valid;
  wire [23:0] left_pcm, right_pcm;
  wire underrun;
  integer sample_count=0;
  reg [23:0] captured_left=0, captured_right=0;
  always #20 clk = ~clk; // 25 MHz
  pcm_audio_player #(.PIXEL_CLOCK_HZ(25_000_000),.SAMPLE_RATE_HZ(48_000)) dut(
    .sample_emitted(),.sample_missing(),.sample_index(),.emitted_count(),.prefetch_ready(),
 .clk(clk),.rst(rst),.fifo_dout(fifo_dout),.fifo_empty(fifo_empty),.playback_mode_async(playback_mode),
    .fifo_re(fifo_re),.audio_valid(audio_valid),.left_pcm(left_pcm),.right_pcm(right_pcm),.underrun(underrun));
  always @(posedge clk) if (audio_valid) begin
    sample_count=sample_count+1;
    captured_left=left_pcm;
    captured_right=right_pcm;
  end
  initial begin
    #200 rst=0;
    // SD 加载期间连续跨过原方波正负半周期，必须始终补零。
    repeat(60000) begin
      @(negedge clk);
      if (audio_valid && (left_pcm!==24'd0 || right_pcm!==24'd0))
        $fatal(1,"Startup FIFO starvation emitted sound");
    end
    if (sample_count<96 || !underrun) $fatal(1,"Startup silence was not exercised");
    rst=1; repeat(3) @(negedge clk); fifo_empty=0; rst=0;
    repeat(600) @(posedge clk);
    if (sample_count==0) $fatal(1,"48 kHz sample enable never asserted");
    // 固定100%幅度，16位PCM左对齐为24位，不改变左右声道顺序。
    if (captured_left !== 24'h567800 || captured_right !== 24'h123400)
      $fatal(1,"PCM scaling/word order failed: L=%h R=%h",captured_left,captured_right);
    if (underrun) $fatal(1,"FIFO prefetch did not complete before first sample");
    fifo_empty=1; repeat(1200) @(negedge clk);
    repeat(30000) begin
      @(negedge clk);
      if (audio_valid && (left_pcm!==24'd0 || right_pcm!==24'd0))
        $fatal(1,"Playback underrun emitted sound");
    end
    if (!underrun) $fatal(1,"Underrun flag missing");
    fifo_empty=0; repeat(1200) @(negedge clk);
    if (captured_left!==24'h567800 || captured_right!==24'h123400)
      $fatal(1,"PCM did not resume after underrun");
    playback_mode=2'd2; repeat(600) @(posedge clk);
    if (captured_left!==24'd0 || captured_right!==24'd0) $fatal(1,"Pause did not mute output");
    playback_mode=2'd0; repeat(4) @(posedge clk);
    if (!fifo_re) $fatal(1,"Stop did not drain stale FIFO data");
    $display("PASS PCM player: startup/underrun silence, recovery, prefetch and scaling");
    $finish;
  end
endmodule
