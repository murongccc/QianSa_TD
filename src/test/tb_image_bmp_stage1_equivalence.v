`timescale 1ns/1ps

// 两种扫描配置分别与旧版对照：完整扫描兼容，以及板级扫描关闭后的加载。
module tb_image_bmp_stage1_equivalence;
parameter integer RAW_SCAN=0;
reg clk=0,rst=1,start_scan=0,start_load=0,sd_valid=0,sd_end=0;
reg [7:0] sd_data=0;
wire old_ready,new_ready,old_scan_done,new_scan_done,old_found,new_found;
wire [31:0] old_found_sector,new_found_sector;
wire [2:0] old_found_total,new_found_total;
wire [3:0] old_state,new_state;
wire [15:0] old_width,new_width,old_height,new_height;
wire old_top,new_top,old_write,new_write,old_req,new_req;
wire [31:0] old_addr,new_addr;
wire old_pixel_valid,new_pixel_valid,old_last,new_last,old_frame,new_frame,old_failed,new_failed;
wire old_bmp_we,new_bmp_we;
wire [23:0] old_pixel,new_pixel,old_bmp,new_bmp;
reg [1:0] transport=0;
reg [9:0] index=0;
integer field=0,value=0,cycles=0,total_cycles=0,cases=0;
reg gap=0;
always #5 clk=~clk;

baseline_bmp_read old_dut(
 .clk(clk),.rst(rst),.ready(old_ready),.scan_start(start_scan),.scan_start_sector(32'd100),.scan_max_sector(32'd100),
 .scan_target_count(3'd1),.scan_done(old_scan_done),.scan_found_valid(old_found),.scan_found_sector(old_found_sector),.scan_found_total(old_found_total),
 .load_start(start_load),.load_sector(32'd100),.sd_init_done(1'b1),.state_code(old_state),.bmp_width(16'd0),.bmp_height(16'd0),
 .parsed_width(old_width),.parsed_height(old_height),.parsed_top_down(old_top),.write_req(old_write),.write_req_ack(1'b1),
 .sd_sec_read(old_req),.sd_sec_read_addr(old_addr),.sd_sec_read_data(sd_data),.sd_sec_read_data_valid(sd_valid),.sd_sec_read_end(sd_end),
 .pixel_valid(old_pixel_valid),.pixel_ready(1'b1),.pixel_data(old_pixel),.pixel_last(old_last),.frame_last(old_frame),.sector_ready(1'b1),
 .load_failed(old_failed),.bmp_data_wr_en(old_bmp_we),.bmp_data(old_bmp),.load_file_mode(1'b0),.load_first_cluster(32'd0),
 .load_file_size(32'd0),.fat_start_sector(32'd0),.first_data_sector(32'd0),.sectors_per_cluster(8'd0));
bmp_read #(.ENABLE_RAW_SCAN(RAW_SCAN)) dut(
 .clk(clk),.rst(rst),.ready(new_ready),.scan_start(start_scan),.scan_start_sector(32'd100),.scan_max_sector(32'd100),
 .scan_target_count(3'd1),.scan_done(new_scan_done),.scan_found_valid(new_found),.scan_found_sector(new_found_sector),.scan_found_total(new_found_total),
 .load_start(start_load),.load_sector(32'd100),.sd_init_done(1'b1),.state_code(new_state),.bmp_width(16'd0),.bmp_height(16'd0),
 .parsed_width(new_width),.parsed_height(new_height),.parsed_top_down(new_top),.write_req(new_write),.write_req_ack(1'b1),
 .sd_sec_read(new_req),.sd_sec_read_addr(new_addr),.sd_sec_read_data(sd_data),.sd_sec_read_data_valid(sd_valid),.sd_sec_read_end(sd_end),
 .pixel_valid(new_pixel_valid),.pixel_ready(1'b1),.pixel_data(new_pixel),.pixel_last(new_last),.frame_last(new_frame),.sector_ready(1'b1),
 .load_failed(new_failed),.bmp_data_wr_en(new_bmp_we),.bmp_data(new_bmp),.load_file_mode(1'b0),.load_first_cluster(32'd0),
 .load_file_size(32'd0),.fat_start_sector(32'd0),.first_data_sector(32'd0),.sectors_per_cluster(8'd0));

function [7:0] sector_byte;
 input [9:0] pos;
 begin
  sector_byte=0;
  case(pos)
   0:sector_byte="B";1:sector_byte="M";2:sector_byte=60;10:sector_byte=54;
   14:sector_byte=40;18:sector_byte=1;22:sector_byte=1;26:sector_byte=1;28:sector_byte=24;
   54:sector_byte=8'h12;55:sector_byte=8'h34;56:sector_byte=8'h56;
   default:;
  endcase
  if(field==0 && pos==0)sector_byte=value;
  if(field==1 && pos==1)sector_byte=value;
 end
endfunction

always @(posedge clk)begin
 sd_valid<=0;sd_end<=0;
 if(rst)begin transport<=0;index<=0;gap<=0;end
 else case(transport)
  0:if(old_req)begin index<=0;transport<=1;end
  1:begin
   if(value[1] && index[2:0]==0 && !gap)gap<=1;
   else begin
    gap<=0;sd_valid<=1;sd_data<=sector_byte(index);
    if(index==511)begin sd_end<=value[0];transport<=2;end else index<=index+1'b1;
   end
  end
  2:begin sd_end<=!value[0];transport<=3;end
  3:if(!old_req)transport<=0;
 endcase
end

always @(negedge clk)if(!rst)begin
 total_cycles=total_cycles+1;
 if({old_ready,old_scan_done,old_found,old_found_sector,old_found_total,old_state,old_width,old_height,old_top,old_write,
     old_req,old_addr,old_pixel_valid,old_pixel,old_last,old_frame,old_failed,old_bmp_we,old_bmp} !==
    {new_ready,new_scan_done,new_found,new_found_sector,new_found_total,new_state,new_width,new_height,new_top,new_write,
     new_req,new_addr,new_pixel_valid,new_pixel,new_last,new_frame,new_failed,new_bmp_we,new_bmp})
  $fatal(1,"BMP output mismatch RAW_SCAN=%0d field=%0d value=%0d",RAW_SCAN,field,value);
 if(old_dut.header_match !== dut.header_match)$fatal(1,"BMP predicate mismatch field=%0d value=%0d",field,value);
end

initial begin
 for(field=0;field<2;field=field+1)begin
  for(value=0;value<256;value=value+1)begin
   @(negedge clk);rst=1;start_scan=0;start_load=0;repeat(3)@(negedge clk);rst=0;
   @(negedge clk);start_scan=RAW_SCAN;start_load=!RAW_SCAN;
   @(negedge clk);start_scan=0;start_load=0;cycles=0;
   while(!old_ready && cycles<2000)begin @(negedge clk);cycles=cycles+1;end
   if(cycles>=2000)$fatal(1,"BMP timeout field=%0d value=%0d",field,value);
   repeat(5)@(negedge clk);cases=cases+1;
  end
 end
 $display("PASS BMP stage1 equivalence RAW_SCAN=%0d cases=%0d compared_cycles=%0d",RAW_SCAN,cases,total_cycles);
 $finish;
end
endmodule
