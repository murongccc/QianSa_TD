`timescale 1ns/1ps

// 真正经过 BPB/目录扇区与同步缓存，穷举替换字段并逐拍比较旧版。
module tb_image_catalog_stage1_equivalence;
parameter integer MBR=0;
reg clk=0,rst=1,sd_valid=0,sd_end=0,release_candidate=0;
reg [7:0] sd_data=0;
wire old_req,new_req,old_valid,new_valid,old_done,new_done;
wire [31:0] old_addr,new_addr,old_cluster,new_cluster,old_size,new_size;
wire [31:0] old_fat,new_fat,old_data,new_data,old_root,new_root;
wire [7:0] old_spc,new_spc;
wire [2:0] old_count,new_count;
wire old_volume,new_volume;
reg [1:0] transport=0;
reg [31:0] address=0;
reg [9:0] index=0;
integer field=0,value=0,cycles=0,total_cycles=0,cases=0;
reg gap=0;
always #5 clk=~clk;

baseline_fat32_bmp_catalog old_dut(
 .clk(clk),.rst(rst),.sd_init_done(1'b1),.sd_sec_read(old_req),.sd_sec_read_addr(old_addr),
 .sd_sec_read_data_valid(sd_valid),.sd_sec_read_data(sd_data),.sd_sec_read_end(sd_end),
 .candidate_valid(old_valid),.candidate_first_cluster(old_cluster),.candidate_file_size(old_size),
 .fat_start_sector(old_fat),.first_data_sector(old_data),.sectors_per_cluster(old_spc),
 .candidate_count(old_count),.candidate_release(release_candidate),.stop(1'b0),
 .scan_done(old_done),.volume_valid(old_volume),.volume_root_cluster(old_root));
fat32_bmp_catalog dut(
 .clk(clk),.rst(rst),.sd_init_done(1'b1),.sd_sec_read(new_req),.sd_sec_read_addr(new_addr),
 .sd_sec_read_data_valid(sd_valid),.sd_sec_read_data(sd_data),.sd_sec_read_end(sd_end),
 .candidate_valid(new_valid),.candidate_first_cluster(new_cluster),.candidate_file_size(new_size),
 .fat_start_sector(new_fat),.first_data_sector(new_data),.sectors_per_cluster(new_spc),
 .candidate_count(new_count),.candidate_release(release_candidate),.stop(1'b0),
 .scan_done(new_done),.volume_valid(new_volume),.volume_root_cluster(new_root));

function [7:0] sector_byte;
 input [31:0] addr;
 input [9:0] pos;
 begin
  sector_byte=0;
  if(MBR && addr==0)begin
   if(pos==450)sector_byte=8'h0b;
   if(pos==454)sector_byte=8'd100;
  end else if(addr==(MBR?32'd100:32'd0))begin
   case(pos)
    11:sector_byte=0;12:sector_byte=2;13:sector_byte=1;
    14:sector_byte=1;16:sector_byte=1;36:sector_byte=1;44:sector_byte=2;
    default:;
   endcase
   if(field==0 && pos==11)sector_byte=value;
   if(field==1 && pos==12)sector_byte=value;
  end else if(addr==(MBR?32'd102:32'd2))begin
   case(pos)
    0:sector_byte="A";8:sector_byte="B";9:sector_byte="M";10:sector_byte="P";
    11:sector_byte=8'h20;
    21:sector_byte=1;26:sector_byte=7;
    28:sector_byte=8'h67;29:sector_byte=8'h45;30:sector_byte=8'h23;31:sector_byte=8'h81;
    default:;
   endcase
   if(field==2 && pos==0)sector_byte=value;
   if(field==3 && pos==8)sector_byte=value;
   if(field==4 && pos==9)sector_byte=value;
   if(field==5 && pos==10)sector_byte=value;
   if(field==6 && pos==11)sector_byte=value;
  end
 end
endfunction

always @(posedge clk)begin
 sd_valid<=0;sd_end<=0;release_candidate<=0;
 if(rst)begin transport<=0;index<=0;gap<=0;end
 else begin
  release_candidate<=old_valid;
  case(transport)
   0:if(old_req)begin address<=old_addr;index<=0;transport<=1;end
   1:begin
    if(value[1] && index[2:0]==0 && !gap)gap<=1;
    else begin
     gap<=0;sd_valid<=1;sd_data<=sector_byte(address,index);
     if(index==511)begin sd_end<=value[0];transport<=2;end
     else index<=index+1'b1;
    end
   end
   2:begin sd_end<=!value[0];transport<=3;end
   3:if(!old_req)transport<=0;
  endcase
 end
end

always @(negedge clk)if(!rst)begin
 total_cycles=total_cycles+1;
 if({old_req,old_addr,old_valid,old_cluster,old_size,old_fat,old_data,old_spc,old_count,old_done,old_volume,old_root} !==
    {new_req,new_addr,new_valid,new_cluster,new_size,new_fat,new_data,new_spc,new_count,new_done,new_volume,new_root})
  $fatal(1,"catalog output mismatch MBR=%0d field=%0d value=%0d",MBR,field,value);
 if(old_dut.bpb_looks_valid !== dut.bpb_looks_valid || old_dut.dir_entry_is_bmp !== dut.dir_entry_is_bmp)
  $fatal(1,"catalog predicate mismatch field=%0d value=%0d",field,value);
end

initial begin
 for(field=0;field<7;field=field+1)begin
  for(value=0;value<256;value=value+1)begin
   @(negedge clk);rst=1;repeat(3)@(negedge clk);rst=0;cycles=0;
   while(!(old_done && !old_valid) && cycles<6000)begin @(negedge clk);cycles=cycles+1;end
   if(cycles>=6000)$fatal(1,"catalog timeout field=%0d value=%0d",field,value);
   repeat(5)@(negedge clk);cases=cases+1;
  end
 end
 $display("PASS catalog stage1 equivalence MBR=%0d cases=%0d compared_cycles=%0d",MBR,cases,total_cycles);
 $finish;
end
endmodule
