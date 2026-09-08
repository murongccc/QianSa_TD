`timescale 1ns/1ps
module tb_fat32_wav_reader;
 reg clk=0,rst=1,sd_init_done=0,sd_data_valid=0,sd_sec_read_end=0,read_toggle=0;
 reg [7:0] sd_data=0;
 wire sd_sec_read,fifo_we,busy,done,file_found,format_ok;
 wire [31:0] sd_sec_read_addr,fifo_din;
 integer i, writes=0;
 always #5 clk=~clk;
 fat32_wav_reader #(.FIFO_SAFE_LEVEL(3968)) dut(
  .clk(clk),.rst(rst),.sd_init_done(sd_init_done),.enable(1'b1),.sd_sec_read(sd_sec_read),.sd_sec_read_addr(sd_sec_read_addr),
  .sd_data(sd_data),.sd_data_valid(sd_data_valid),.sd_sec_read_end(sd_sec_read_end),.fifo_we(fifo_we),.fifo_din(fifo_din),
  .fifo_full(1'b0),.audio_read_toggle(read_toggle),.busy(busy),.done(done),.file_found(file_found),.format_ok(format_ok),.format_error());
 task byte(input [7:0] v); begin @(negedge clk);sd_data=v;sd_data_valid=1;@(negedge clk);sd_data_valid=0;end endtask
 task end_sector; begin @(negedge clk);sd_sec_read_end=1;@(negedge clk);sd_sec_read_end=0;end endtask
 task send_sector(input [31:0] addr); begin
  wait(sd_sec_read && sd_sec_read_addr==addr);
  for(i=0;i<512;i=i+1) begin
   if(addr==0 && i>=454 && i<=457) byte((i==454)?0:(i==455)?8:(i==456)?0:0);
   else if(addr==2048 && i==13) byte(1);
   else if(addr==2048 && i==14) byte(32);
   else if(addr==2048 && i==15) byte(0);
   else if(addr==2048 && i==16) byte(2);
   else if(addr==2048 && i==36) byte(1);
   else if(addr==2048 && i>=37 && i<=39) byte(0);
   else if(addr==2048 && i==44) byte(2);
   else if(addr==2048 && i>=45 && i<=47) byte(0);
   else if(addr==2082 && i==0) byte("W"); else if(addr==2082 && i==1) byte("A"); else if(addr==2082 && i==2) byte("N"); else if(addr==2082 && i==3) byte("_");
   else if(addr==2082 && i==4) byte("C"); else if(addr==2082 && i==5) byte("A"); else if(addr==2082 && i==6) byte("N"); else if(addr==2082 && i==7) byte("_");
   else if(addr==2082 && i==8) byte("W"); else if(addr==2082 && i==9) byte("A"); else if(addr==2082 && i==10) byte("V");
   else if(addr==2082 && i==26) byte(5); else if(addr==2082 && i==27) byte(0); else if(addr==2082 && i==31) byte(1);
   else if(addr==2082 && i==28) byte(128); else if(addr==2082 && i==29) byte(0); else if(addr==2082 && i==30) byte(0);
   else if(addr==2085 && i==0) byte("R"); else if(addr==2085 && i==1) byte("I"); else if(addr==2085 && i==2) byte("F"); else if(addr==2085 && i==3) byte("F");
   else if(addr==2085 && i==8) byte("W"); else if(addr==2085 && i==9) byte("A"); else if(addr==2085 && i==10) byte("V"); else if(addr==2085 && i==11) byte("E");
   else if(addr==2085 && i==12) byte("f"); else if(addr==2085 && i==13) byte("m"); else if(addr==2085 && i==14) byte("t"); else if(addr==2085 && i==15) byte(" ");
   else if(addr==2085 && i==16) byte(16); else if(addr==2085 && i==20) byte(1); else if(addr==2085 && i==22) byte(2);
   else if(addr==2085 && i==24) byte(8'h80); else if(addr==2085 && i==25) byte(8'hbb); else if(addr==2085 && i==34) byte(16);
   else if(addr==2085 && i==36) byte("d"); else if(addr==2085 && i==37) byte("a"); else if(addr==2085 && i==38) byte("t"); else if(addr==2085 && i==39) byte("a"); else if(addr==2085 && i==40) byte(4);
   else if(addr==2085 && i==44) byte(8'h34); else if(addr==2085 && i==45) byte(8'h12); else if(addr==2085 && i==46) byte(8'h78); else if(addr==2085 && i==47) byte(8'h56);
   else byte(0);
  end
  end_sector;
 end endtask
 always @(posedge clk) if(fifo_we) begin writes=writes+1; if(writes==1 && fifo_din!==32'h5678_1234)$fatal(1,"PCM byte order incorrect: %h",fifo_din); end
 initial begin
  #25 rst=0;sd_init_done=1;
  send_sector(0);send_sector(2048);send_sector(2082);send_sector(2085);
  #100;
  if(!file_found)$fatal(1,"WAV directory entry not found");
  if(!format_ok)$fatal(1,"WAV format header rejected");
  if(writes!=1)$fatal(1,"expected exactly one PCM frame, got %0d",writes);
  $display("PASS WAV reader: %0d PCM frames",writes);$finish;
 end
endmodule
