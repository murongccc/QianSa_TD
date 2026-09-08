`timescale 1ns/1ps
module tb_fat32_fat_reader;
 reg clk=0,rst=1,start=0,byte_valid=0,sector_done=0;
 reg [31:0] cluster=32'd130, fat_start_sector=32'd1000;
 reg [7:0] byte_data=0; reg [8:0] byte_index=0; reg [7:0] sectors_per_cluster=1;
 wire request,done,end_of_chain; wire [31:0] request_sector,next_cluster;
 always #5 clk=~clk;
 fat32_fat_reader dut(.clk(clk),.rst(rst),.start(start),.cluster(cluster),.fat_start_sector(fat_start_sector),.sectors_per_cluster(sectors_per_cluster),.request(request),.request_sector(request_sector),.byte_valid(byte_valid),.byte_index(byte_index),.byte_data(byte_data),.sector_done(sector_done),.done(done),.next_cluster(next_cluster),.end_of_chain(end_of_chain));
 task put(input [8:0] i,input [7:0] d); begin @(negedge clk); byte_index=i;byte_data=d;byte_valid=1; @(negedge clk);byte_valid=0; end endtask
 initial begin
  #20 rst=0; #10 start=1; #10 start=0;
  put(9'd8,8'h34); put(9'd9,8'h12); put(9'd10,8'h00); put(9'd11,8'h00);
  @(negedge clk);sector_done=1; @(negedge clk);sector_done=0; #20;
  if(next_cluster!==32'h00001234) $display("FAIL next=%h",next_cluster); else $display("PASS FAT reader");
  $finish;
 end
endmodule
