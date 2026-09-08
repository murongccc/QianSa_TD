module fat32_single_audio_controller(
 input wire clk,input wire rst,input wire sd_init_done,
 output reg sd_sec_read,output reg [31:0] sd_sec_read_addr,
 input wire [7:0] sd_data,input wire sd_data_valid,input wire sd_sec_read_end,
 output reg fifo_we,output reg [31:0] fifo_din,input wire fifo_full,
 output reg busy,output reg file_found,output reg done
);
 localparam IDLE=0,MBR=1,BPB=2,DIR=3,FAT=4,DATA=5,HOLD=6;
 reg [2:0] state; reg [8:0] pos; reg [31:0] part_lba,fat_start,data_start,root_cluster,current_cluster,fat_raw,file_size,file_pos;
 reg [15:0] reserved; reg [7:0] spc,fat_count; reg [31:0] spf; reg [1:0] pcm_index; reg [7:0] p0,p1,p2; reg [31:0] sector_in_cluster;
 reg [7:0] ent[0:31]; integer i;
 wire [8:0] fat_offset=(current_cluster[6:0]<<2); wire [31:0] cluster_lba=data_start+((current_cluster-2)*spc);
 always @(posedge clk or posedge rst) begin
  if(rst) begin state<=IDLE;pos<=0;sd_sec_read<=0;sd_sec_read_addr<=0;fifo_we<=0;fifo_din<=0;busy<=0;file_found<=0;done<=0;part_lba<=0;fat_start<=0;data_start<=0;root_cluster<=0;current_cluster<=0;fat_raw<=0;file_size<=0;file_pos<=0;reserved<=0;spc<=0;fat_count<=0;spf<=0;pcm_index<=0;sector_in_cluster<=0;for(i=0;i<32;i=i+1)ent[i]<=0;end
  else begin fifo_we<=0;done<=0;case(state)
   IDLE:if(sd_init_done)begin busy<=1;file_found<=0;pos<=0;sd_sec_read_addr<=0;sd_sec_read<=1;state<=MBR;end
   MBR:begin if(sd_data_valid)begin if(pos==454)part_lba[7:0]<=sd_data;if(pos==455)part_lba[15:8]<=sd_data;if(pos==456)part_lba[23:16]<=sd_data;if(pos==457)part_lba[31:24]<=sd_data;pos<=pos+1;end if(sd_sec_read_end)begin sd_sec_read<=0;pos<=0;sd_sec_read_addr<=part_lba;sd_sec_read<=1;state<=BPB;end end
   BPB:begin if(sd_data_valid)begin if(pos==13)spc<=sd_data;if(pos==14)reserved[7:0]<=sd_data;if(pos==15)reserved[15:8]<=sd_data;if(pos==16)fat_count<=sd_data;if(pos>=36&&pos<=39)spf[(pos-36)*8 +:8]<=sd_data;if(pos>=44&&pos<=47)root_cluster[(pos-44)*8 +:8]<=sd_data;pos<=pos+1;end if(sd_sec_read_end)begin sd_sec_read<=0;pos<=0;fat_start<=part_lba+reserved;data_start<=part_lba+reserved+(fat_count*spf);sd_sec_read_addr<=part_lba+reserved+(fat_count*spf)+((root_cluster-2)*spc);sd_sec_read<=1;state<=DIR;end end
   DIR:begin if(sd_data_valid)begin ent[pos[4:0]]<=sd_data;pos<=pos+1;end if(sd_data_valid&&pos[4:0]==31)begin if(ent[0]=="W"&&ent[1]=="A"&&ent[2]=="N"&&ent[3]=="_"&&ent[4]=="C"&&ent[5]=="A"&&ent[6]=="N"&&(ent[7]=="_"||ent[7]==8'h7e)&&ent[8]=="W"&&ent[9]=="A"&&ent[10]=="V"&&ent[11]!=8'h0f)begin file_found<=1;current_cluster<={ent[21],ent[20],ent[27],ent[26]};file_size<={sd_data,ent[30],ent[29],ent[28]};sd_sec_read<=0;state<=FAT;end else if(ent[0]==0)begin busy<=0;done<=1;sd_sec_read<=0;state<=HOLD;end end end
   FAT:begin sd_sec_read_addr<=fat_start+(current_cluster>>7);sd_sec_read<=1;pos<=0;state<=DATA;end
   DATA:begin if(sd_data_valid)begin if(pos==fat_offset)fat_raw[7:0]<=sd_data;if(pos==fat_offset+1)fat_raw[15:8]<=sd_data;if(pos==fat_offset+2)fat_raw[23:16]<=sd_data;if(pos==fat_offset+3)fat_raw[31:24]<=sd_data;pos<=pos+1;end if(sd_sec_read_end)begin sd_sec_read<=0;sd_sec_read_addr<=cluster_lba;sd_sec_read<=1;pos<=0;sector_in_cluster<=0;state<=HOLD;end end
   HOLD:begin if(sd_data_valid&&file_pos<file_size)begin file_pos<=file_pos+1;if(file_pos>=44&&!fifo_full)begin case(pcm_index)0:p0<=sd_data;1:p1<=sd_data;2:p2<=sd_data;3:begin fifo_din<={sd_data,p2,p1,p0};fifo_we<=1;end endcase pcm_index<=pcm_index+1;end end if(sd_sec_read_end)begin sd_sec_read<=0;if(file_pos>=file_size)begin busy<=0;done<=1;end else if(sector_in_cluster+1<spc)begin sector_in_cluster<=sector_in_cluster+1;sd_sec_read_addr<=sd_sec_read_addr+1;sd_sec_read<=1;end else begin current_cluster<=fat_raw&32'h0fffffff;state<=FAT;end end end
  endcase end
 end
endmodule
