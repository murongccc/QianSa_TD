`timescale 1ns/1ps
module tb_pcm_audio_player;
  reg clk=0, rst=1, fifo_empty=0;
  reg [2:0] volume_level=3'd4;
  reg [1:0] playback_mode=2'd1;
  reg [31:0] fifo_dout=32'h1234_5678;
  wire fifo_re, audio_valid;
  wire [23:0] left_pcm, right_pcm;
  wire underrun;
  integer sample_count=0;
  reg [23:0] captured_left=0, captured_right=0;
  always #20 clk = ~clk; // 25 MHz
  pcm_audio_player #(.PIXEL_CLOCK_HZ(25_000_000),.SAMPLE_RATE_HZ(48_000)) dut(
    .clk(clk),.rst(rst),.fifo_dout(fifo_dout),.fifo_empty(fifo_empty),.volume_level_async(volume_level),.playback_mode_async(playback_mode),
    .fifo_re(fifo_re),.audio_valid(audio_valid),.left_pcm(left_pcm),.right_pcm(right_pcm),.underrun(underrun));
  always @(posedge clk) if (audio_valid) begin
    sample_count=sample_count+1;
    captured_left=left_pcm;
    captured_right=right_pcm;
  end
  initial begin
    #200 rst=0;
    repeat(600) @(posedge clk);
    if (sample_count==0) $fatal(1,"48 kHz sample enable never asserted");
    // At level 4, 16-bit PCM is left-aligned into the HDMI 24-bit word.
    if (captured_left !== 24'h567800 || captured_right !== 24'h123400)
      $fatal(1,"PCM scaling/word order failed: L=%h R=%h",captured_left,captured_right);
    if (underrun) $fatal(1,"FIFO prefetch did not complete before first sample");
    playback_mode=2'd2; repeat(600) @(posedge clk);
    if (captured_left!==24'd0 || captured_right!==24'd0) $fatal(1,"Pause did not mute output");
    playback_mode=2'd0; repeat(4) @(posedge clk);
    if (!fifo_re) $fatal(1,"Stop did not drain stale FIFO data");
    $display("PASS PCM player: synchronous FIFO prefetch and 16-to-24 scaling");
    $finish;
  end
endmodule
