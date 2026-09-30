`timescale 1ns/1ps
// Regression: WAV reader must remain inactive while the BMP catalogue is
// being built, then issue its MBR request once a display frame is committed.
module tb_sd_media_audio_start;
 reg clk=0,rst=1,sd_init_done=0,enable=0;
 wire sd_sec_read,busy;
 wire [31:0] sd_sec_read_addr;
 fat32_wav_reader dut(
  .clk(clk),.rst(rst),.sd_init_done(sd_init_done),.enable(enable),
  .sd_sec_read(sd_sec_read),.sd_sec_read_addr(sd_sec_read_addr),
  .sd_data(8'd0),.sd_data_valid(1'b0),.sd_sec_read_end(1'b0),.fifo_we(),.fifo_din(),.fifo_full(1'b0),
  .audio_read_toggle(1'b0),.audio_fifo_level(),.busy(busy),.done(),.file_found(),.format_ok(),.format_error(),
  .volume_valid(1'b0),.volume_fat_start(32'd0),.volume_data_start(32'd0),
  .volume_root_cluster(32'd0),.volume_sectors_per_cluster(8'd0));
 always #5 clk=~clk;
 initial begin
  #20 rst=0; sd_init_done=1;
  repeat(20) @(posedge clk);
  if(sd_sec_read || busy) $fatal(1,"WAV started before first BMP frame");
  enable=1;
  repeat(2) @(posedge clk);
  if(!sd_sec_read || !busy || sd_sec_read_addr!=0) $fatal(1,"WAV did not start after display enable");
  $display("PASS deferred audio start"); $finish;
 end
endmodule
