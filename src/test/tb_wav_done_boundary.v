`timescale 1ns/1ps
// FAT 第四字节和末目录项最后字节与 done 同拍，必须消费更新后的数据。
module tb_wav_done_boundary;
reg clk=0,rst=1,valid=0,done=0;
reg [7:0] data=0;
always #5 clk=~clk;
fat32_wav_reader #(.ENABLE_GAME(1),.USE_SHARED_VOLUME(1)) dut(
 .clk(clk),.rst(rst),.sd_init_done(1'b0),.enable(1'b0),.sd_sec_read(),.sd_sec_read_addr(),
 .sd_data(data),.sd_data_valid(valid),.sd_sec_read_end(done),.fifo_we(),.fifo_din(),.fifo_full(1'b0),
 .audio_read_toggle(1'b0),.audio_fifo_level(),.busy(),.done(),.file_found(),.format_ok(),.format_error(),.format_error_detail(),
 .volume_valid(1'b0),.volume_fat_start(32'd0),.volume_data_start(32'd0),.volume_root_cluster(32'd0),
 .volume_sectors_per_cluster(8'd0),.game_mode(1'b1),.cancel(1'b0),.song_frames(),.song_frames_valid(),
 .stream_eof(),.cancelled());
integer n;
task reset_all;
 begin rst=1;valid=0;done=0;repeat(2)@(negedge clk);rst=0;end
endtask
initial begin
 for(n=0;n<4;n=n+1)begin
  reset_all;dut.game_session=n[0];dut.state=n<2?5'd8:5'd11;
  dut.pos=9'd511;dut.fat_offset=9'd508;dut.fat_next=32'd3;
  data=8'ha1;valid=1;done=1;@(negedge clk);valid=0;done=0;
  wait(dut.state==5'd12);@(negedge clk);
  if(dut.cluster!==32'h01000003)$fatal(1,"FAT fourth byte lost");
 end
 for(n=0;n<2;n=n+1)begin
  reset_all;dut.game_session=n[0];dut.state=5'd3;dut.pos=9'd511;
  dut.name_match=1;dut.entry_first="G";dut.entry_ext=24'h564157;dut.entry_attr=8'h20;
  dut.entry_cluster=32'd127;dut.entry_size_low=24'd48;
  data=0;valid=1;done=1;@(negedge clk);valid=0;done=0;
  wait(dut.state==5'd12);@(negedge clk);
  if(!dut.file_found || dut.cluster!==32'd127 || dut.file_size!==32'd48 || dut.expected_length!==32'd40)
   $fatal(1,"last directory entry lost, mode=%0d",n);
 end
 $display("PASS WAV done boundaries: both FAT paths and media/game directory");$finish;
end
initial begin #10000;$fatal(1,"boundary timeout");end
endmodule
