`timescale 1ns/1ps
module tb_fat32_audio_controller;
 reg clk=0,rst=1,sd_init_done=0,sd_data_valid=0,sd_end=0;
 reg [7:0] sd_data=0; wire sd_read; wire [31:0] sd_addr;
 wire busy,found,done; wire [31:0] fcluster,fsize;
 wire fifo_we; wire [31:0] fifo_din;
 integer i;
 always #5 clk=~clk;
 fat32_audio_controller dut(.clk(clk),.rst(rst),.sd_init_done(sd_init_done),
  .sd_sec_read(sd_read),.sd_sec_read_addr(sd_addr),.sd_sec_read_data(sd_data),
  .sd_sec_read_data_valid(sd_data_valid),.sd_sec_read_end(sd_end),.fifo_we(fifo_we),.fifo_din(fifo_din),.fifo_full(1'b0),.busy(busy),.file_found(found),.done(done),.file_start_cluster(fcluster),.file_size(fsize),.data_start_sector(),.data_sectors_per_cluster());
 task send_byte(input [8:0] idx,input [7:0] val); begin @(negedge clk); sd_data=val; sd_data_valid=1; @(negedge clk); sd_data_valid=0; end endtask
 task end_sector; begin @(negedge clk); sd_end=1; @(negedge clk); sd_end=0; end endtask
 task send_sector(input [31:0] addr); integer j; begin
   wait(sd_read && sd_addr==addr);
   for(j=0;j<512;j=j+1) begin
     if(addr==0 && j>=454 && j<=457) send_byte(j,(j==454)?8'h00:(j==455)?8'h08:(j==456)?8'h00:8'h00);
     else if(addr==2048 && j==13) send_byte(j,8'd1);
     else if(addr==2048 && j==14) send_byte(j,8'd32);
     else if(addr==2048 && j==15) send_byte(j,8'd0);
     else if(addr==2048 && j==16) send_byte(j,8'd2);
     else if(addr==2048 && j>=36 && j<=39) send_byte(j,(j==36)?8'd1:0);
     else if(addr==2048 && j>=44 && j<=47) send_byte(j,(j==44)?8'd2:0);
     else if(addr==2082 && j==0) send_byte(j,8'h57);
     else if(addr==2082 && j==1) send_byte(j,8'h41);
     else if(addr==2082 && j==2) send_byte(j,8'h4E);
     else if(addr==2082 && j==3) send_byte(j,8'h5F);
     else if(addr==2082 && j==4) send_byte(j,8'h43);
     else if(addr==2082 && j==5) send_byte(j,8'h41);
     else if(addr==2082 && j==6) send_byte(j,8'h4E);
     else if(addr==2082 && j==7) send_byte(j,8'h5F);
     else if(addr==2082 && j==8) send_byte(j,8'h57);
     else if(addr==2082 && j==9) send_byte(j,8'h41);
     else if(addr==2082 && j==10) send_byte(j,8'h56);
     else if(addr==2082 && j==26) send_byte(j,8'd5);
     else if(addr==2082 && j==28) send_byte(j,8'h00);
     else if(addr==2082 && j==29) send_byte(j,8'h10);
     else if(addr==2082 && j==30) send_byte(j,8'h00);
     else if(addr==2082 && j==31) send_byte(j,8'h00);
     else send_byte(j,0);
   end
   end_sector;
 end endtask
 initial begin
   #20 rst=0; #20 sd_init_done=1;
   send_sector(0); send_sector(2048); send_sector(2082);
   #1000;
   if(found && fcluster==32'd5 && fsize==32'h00001000) $display("PASS FAT32 filename locate cluster=%0d size=%0d",fcluster,fsize);
   else $display("FAIL found=%b cluster=%h size=%h addr=%h",found,fcluster,fsize,sd_addr);
   $finish;
 end
endmodule
