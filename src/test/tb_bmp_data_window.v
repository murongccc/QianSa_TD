`timescale 1ns/1ps
// 高位文件位置直接注入；验证窗口边界及尾部跨 32 位回绕后不重新打开。
module tb_bmp_data_window;
reg clk=0,rst=1,sd_valid=0,sd_end=0;
reg [7:0] sd_data=0;
wire load_failed,pixel_valid,pixel_last,frame_last,parsed_top_down;
wire [23:0] pixel_data;
wire [15:0] parsed_width,parsed_height;
always #5 clk=~clk;
bmp_read dut(
    .clk(clk),.rst(rst),.ready(),
    .scan_start(1'b0),.scan_start_sector(32'd0),.scan_max_sector(32'd0),
    .scan_target_count(3'd0),.scan_done(),.scan_found_valid(),
    .scan_found_sector(),.scan_found_total(),
    .load_start(1'b0),.load_sector(32'd100),.sd_init_done(1'b1),
    .state_code(),.bmp_width(16'd0),.bmp_height(16'd0),
    .parsed_width(parsed_width),.parsed_height(parsed_height),
    .parsed_top_down(parsed_top_down),.write_req(),.write_req_ack(1'b0),
    .sd_sec_read(sd_read),.sd_sec_read_addr(),.sd_sec_read_data(sd_data),
    .sd_sec_read_data_valid(sd_valid),.sd_sec_read_end(sd_end),
    .pixel_valid(pixel_valid),.pixel_ready(1'b1),.pixel_data(pixel_data),
    .pixel_last(pixel_last),.frame_last(frame_last),.sector_ready(1'b1),
    .load_failed(load_failed),.bmp_data_wr_en(),.bmp_data(),
    .load_file_mode(1'b0),.load_first_cluster(32'd0),.load_file_size(32'd0),
    .fat_start_sector(32'd0),.first_data_sector(32'd0),.sectors_per_cluster(8'd0)
);
integer n,j,pixels;
reg [31:0] offset;
reg [63:0] position;
reg expected_valid;
always @(posedge clk)if(!rst && pixel_valid)pixels=pixels+1;
initial begin
 for(n=0;n<2;n=n+1)begin
  rst=1;sd_valid=0;sd_end=0;repeat(2)@(negedge clk);rst=0;
  offset=n==0?32'h01000400:32'hfffffff4;
  dut.state=4'd4;dut.file_len=offset+32'd8;dut.pixel_offset=offset;
  dut.bmp_len_cnt=offset-32'd4;dut.parsed_width=16'd2;dut.parsed_height=16'd1;
  dut.row_stride=13'd8;dut.frame_seen=0;dut.payload_started=0;dut.payload_ended=0;
  dut.row_byte_cnt=0;dut.bmp_byte_idx=0;dut.src_col=0;dut.src_row=0;
  dut.file_mode_latched=0;pixels=0;
  for(j=0;j<28;j=j+1)begin
   position={32'd0,offset}-64'd4+j;
   expected_valid=position>={32'd0,offset} && position<{32'd0,offset}+64'd8;
   sd_valid=1;sd_data=j;sd_end=j==27;
   #1;if(dut.bmp_data_valid!==expected_valid)$fatal(1,"window full-width validity mismatch");
   @(negedge clk);
  end
  sd_valid=0;sd_end=0;repeat(3)@(negedge clk);
  if(pixels!=2 || load_failed || dut.state!=0)$fatal(1,"window EOF pixels=%0d failed=%b",pixels,load_failed);
 end
 $display("PASS BMP full-width window: high offset, EOF, trailing bytes and 32-bit wrap");$finish;
end
endmodule
