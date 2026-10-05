`timescale 1ns/1ps
// 穷举旧错误码译码与新的并行就绪判断，包含高位帧数差异及取消。
module tb_sd_resource_ready_equivalence;
reg clk=0,game_mode=0,cancel=0,enable=0;
always #5 clk=~clk;
reg [3:0] chart_error=0;
reg overflow=0,wav_missing=0,wav_bad=0,header_valid=0,wav_valid=0,cancelled=0;
reg [31:0] chart_frames=32'ha5a5_5a5a,wav_frames=0,audio_level=0;
reg [7:0] chart_used=0;
reg chart_eof=0,audio_eof=0;
wire [3:0] error_code;
wire resources_ready;
wire startup_ready=dut.startup_ready;
reg [3:0] expected_error;
reg expected_startup,expected_ready;
integer value;
rhythm_sd_resources #(.REUSE_MEDIA(1)) dut(
 .clk(clk),.note_clk(clk),.rst(1'b1),.enable(enable),.cancel(cancel),.metadata_address(6'd0),.metadata_data(),
 .game_mode(game_mode),.volume_valid(1'b0),.volume_fat_start(32'd0),.volume_data_start(32'd0),
 .volume_root_cluster(32'd0),.volume_sectors_per_cluster(8'd0),.bmp_req(1'b0),.bmp_addr(32'd0),
 .bmp_valid(),.bmp_done(),.bmp_data(),.response_busy(),.sd_req(),.sd_addr(),.sd_data(8'd0),.sd_valid(1'b0),.sd_done(1'b0),
 .audio_fifo_we(),.audio_fifo_data(),.audio_fifo_full(1'b0),.audio_read_toggle(1'b0),.audio_fifo_level(),
 .note_ready(1'b0),.note_valid(),.note_data(),.header_valid(),.song_frames(),.note_count(),.hold_count(),
 .offset_samples(),.title(),.difficulty(),.resources_ready(resources_ready),.cancelled(),
 .wav_busy(),.wav_done(),.wav_found(),.wav_format_ok(),.wav_format_error(),.audio_eof(),.chart_eof(),.error_code(error_code));
initial begin
 force dut.chart_error=chart_error;force dut.overflow=overflow;force dut.wav_missing=wav_missing;
 force dut.wav_bad=wav_bad;force dut.header_valid=header_valid;force dut.wav_frames_valid=wav_valid;
 force dut.song_frames=chart_frames;force dut.wav_frames=wav_frames;force dut.cancelled=cancelled;
 force dut.chart_used=chart_used;force dut.chart_eof=chart_eof;force dut.audio_fifo_level=audio_level;
 force dut.audio_eof=audio_eof;force dut.ready_latched=1'b1;
 for(value=0;value<65536;value=value+1)begin
  chart_error=value[3:0];overflow=value[4];wav_missing=value[5];wav_bad=value[6];
  header_valid=value[7];wav_valid=value[8];
  wav_frames=chart_frames^(value[9] ? (32'd1<<value[4:0]) : 32'd0);
  game_mode=value[10];cancel=value[11];cancelled=value[12];
  chart_used=value[13] ? 8'd64 : 8'd1;chart_eof=value[5];
  audio_level=value[14] ? 32'd2048 : 32'd1;audio_eof=value[6];enable=value[15];
  if(!game_mode)expected_error=4'd0;
  else if(chart_error!=4'd0)expected_error=chart_error;
  else if(overflow)expected_error=4'd6;
  else if(wav_missing)expected_error=4'd7;
  else if(wav_bad)expected_error=4'd8;
  else if(header_valid && wav_valid && chart_frames!=wav_frames)expected_error=4'd9;
  else expected_error=4'd0;
  expected_startup=!game_mode ? (enable && audio_level>=32'd2048) :
   (expected_error==4'd0 && !cancel && !cancelled && header_valid && wav_valid &&
    (chart_used>=8'd64 || (chart_eof && chart_used!=8'd0)) &&
    (audio_level>=32'd2048 || (audio_eof && audio_level!=32'd0)));
  expected_ready=!cancel && !cancelled && expected_error==4'd0;
  #1;
  if(error_code!==expected_error || startup_ready!==expected_startup || resources_ready!==expected_ready)
   $fatal(1,"ready/error equivalence failed vector=%0d",value);
 end
 $display("PASS resource ready equivalence: 65536 vectors, all 32 frame bits, original error priority and cancellation");
 $finish;
end
endmodule
