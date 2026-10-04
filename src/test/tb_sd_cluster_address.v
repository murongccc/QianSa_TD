`timescale 1ns/1ps
// 独立覆盖两条原地移位寻址通路；首簇及 FAT 跳簇保留 32 位截断结果。
module tb_sd_cluster_address;
reg clk=0,rst=1;
always #5 clk=~clk;
wire [31:0] catalog_addr,bmp_addr;
wire bmp_failed;
fat32_bmp_catalog catalog(
 .clk(clk),.rst(rst),.sd_init_done(1'b0),.sd_sec_read(),.sd_sec_read_addr(catalog_addr),
 .sd_sec_read_data_valid(1'b0),.sd_sec_read_data(8'd0),.sd_sec_read_end(1'b0),
 .candidate_valid(),.candidate_first_cluster(),.candidate_file_size(),.fat_start_sector(),
 .first_data_sector(),.sectors_per_cluster(),.candidate_count(),.candidate_release(1'b0),
 .stop(1'b0),.scan_done(),.volume_valid(),.volume_root_cluster());
bmp_read bmp(
 .clk(clk),.rst(rst),.ready(),.scan_start(1'b0),.scan_start_sector(32'd0),.scan_max_sector(32'd0),
 .scan_target_count(3'd0),.scan_done(),.scan_found_valid(),.scan_found_sector(),.scan_found_total(),
 .load_start(1'b0),.load_sector(32'd0),.sd_init_done(1'b1),.state_code(),.bmp_width(16'd0),.bmp_height(16'd0),
 .parsed_width(),.parsed_height(),.parsed_top_down(),.write_req(),.write_req_ack(1'b0),
 .sd_sec_read(),.sd_sec_read_addr(bmp_addr),.sd_sec_read_data(8'd0),.sd_sec_read_data_valid(1'b0),
 .sd_sec_read_end(1'b0),.pixel_valid(),.pixel_ready(1'b1),.pixel_data(),.pixel_last(),.frame_last(),
 .sector_ready(1'b0),.load_failed(bmp_failed),.bmp_data_wr_en(),.bmp_data(),.load_file_mode(1'b1),
 .load_first_cluster(32'd0),.load_file_size(32'd0),.fat_start_sector(32'd0),
 .first_data_sector(32'd0),.sectors_per_cluster(8'd0));
integer n,j;
reg legal;
reg [31:0] cluster_value,expected;
task reset_all;
 begin rst=1;repeat(2)@(negedge clk);rst=0;end
endtask
initial begin
 for(n=0;n<256;n=n+1)begin
  legal=n!=0 && (n & (n-1))==0;
  for(j=0;j<3;j=j+1)begin
   reset_all;
   case(j)0:cluster_value=32'd2;1:cluster_value=32'd12345;2:cluster_value=32'h0fff_ff00;endcase
   expected=32'h1234_0000+(cluster_value-32'd2)*n;
   catalog.state=5'd4;catalog.dir_cluster=cluster_value;
   catalog.first_data_sector=32'h1234_0000;catalog.sectors_per_cluster=n;
   bmp.state=4'd11;bmp.file_cluster=cluster_value;
   bmp.first_data_sector_latched=32'h1234_0000;bmp.sectors_per_cluster_latched=n;
   if(legal)begin
    wait(catalog.state==5'd5 && bmp.state==4'd2);@(negedge clk);
    if(catalog_addr!==expected || bmp_addr!==expected || bmp_failed)
     $fatal(1,"first cluster address spc=%0d cluster=%h",n,cluster_value);
    // 再次跳簇须重新加载移位计数，不能沿用首簇计算后的 1。
    bmp.state=4'd14;bmp.fat_entry=cluster_value+32'd9;
    expected=32'h1234_0000+(cluster_value+32'd7)*n;
    wait(bmp.state==4'd6);@(negedge clk);
    if(bmp_addr!==expected || bmp_failed)$fatal(1,"FAT cluster address spc=%0d",n);
   end else begin
    repeat(12)@(negedge clk);
    if(catalog.state!=5'd8 || bmp.state!=4'd0 || !bmp_failed)
     $fatal(1,"invalid spc accepted: %0d",n);
   end
  end
 end
 $display("PASS SD cluster addressing: all 256 spc, first and next fragments");$finish;
end
initial begin #2000000;$fatal(1,"address timeout");end
endmodule
