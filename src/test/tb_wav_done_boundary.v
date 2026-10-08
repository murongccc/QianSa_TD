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
 // 保留原 1024 扇区扫描上限及末字节退场后的计数。
 for(n=1022;n<=1023;n=n+1)begin
  reset_all;dut.game_session=1;dut.state=5'd19;dut.file_found=0;
  dut.game_dir_end=0;dut.game_dir_sectors=n;dut.sector_in_cluster=0;dut.spc=64;dut.sector=200;
  repeat(3)@(negedge clk);
  if(dut.game_dir_sectors!==n+1)$fatal(1,"directory count was lost or duplicated");
  if(n==1022 && (!dut.sd_sec_read || dut.sd_sec_read_addr!=201))$fatal(1,"directory stopped early");
  if(n==1023 && (dut.sd_sec_read || dut.state!=5'd9))$fatal(1,"directory limit was bypassed");
 end
 $display("PASS WAV done boundaries: both FAT paths, media/game directory and scan limit");$finish;
end
initial begin #10000;$fatal(1,"boundary timeout");end
endmodule
