// WAV file reader for the common SD SPI path.
// Reads root-directory WAN_CAN_.WAV: FAT32, PCM 48 kHz, 16-bit stereo.
// The producer reserves room for a whole sector before requesting it, so an
// unpausable SD sector never overflows the asynchronous audio FIFO.
module fat32_wav_reader #(
 parameter integer FIFO_SAFE_LEVEL=3968
)(
 input wire clk,input wire rst,input wire sd_init_done,input wire enable,
 output reg sd_sec_read,output reg [31:0] sd_sec_read_addr,
 input wire [7:0] sd_data,input wire sd_data_valid,input wire sd_sec_read_end,
 output reg fifo_we,output reg [31:0] fifo_din,input wire fifo_full,
 input wire audio_read_toggle,
 output reg busy,output reg done,output reg file_found,output reg format_ok,
 output reg format_error
);
 localparam IDLE=0,MBR=1,BPB=2,DIR=3,DIR_FOUND=4,WAIT=5,DATA=6,ST_FAT=7,ST_FATDATA=8,HOLD=9,DIR_FAT=10,ST_DIR_FATDATA=11;
 reg [3:0] state; reg [8:0] pos,fat_offset; reg [7:0] ent[0:31]; integer i;
 reg [31:0] part,fat_start,data_start,root,first_cluster,cluster,sector,file_size,file_pos,fat_next;
 reg [31:0] spf;
 reg [15:0] reserved; reg [7:0] spc,fats,sector_in_cluster;
 reg [31:0] fifo_level; reg read_meta,read_sync,read_seen;
 reg [1:0] pcm_index; reg [7:0] p0,p1,p2; reg [31:0] wav_data_remaining;
 reg [7:0] h[0:43]; reg [5:0] header_pos;
 reg [7:0] chunk_id0,chunk_id1,chunk_id2,chunk_id3;
 reg [31:0] chunk_size,chunk_skip_remaining;
 reg [3:0] chunk_header_pos;
 reg data_found;
 reg format_error_pending;
 wire base_header_valid=(h[0]=="R"&&h[1]=="I"&&h[2]=="F"&&h[3]=="F"&&
                    h[8]=="W"&&h[9]=="A"&&h[10]=="V"&&h[11]=="E"&&
                    h[12]=="f"&&h[13]=="m"&&h[14]=="t"&&h[15]==" "&&
                    h[20]==8'd1&&h[21]==0&&h[22]==8'd2&&h[23]==0&&
                    h[24]==8'h80&&h[25]==8'hbb&&h[26]==0&&h[27]==0&&
                    h[34]==8'd16&&h[35]==0);
 wire read_event=read_sync!=read_seen;
 wire fifo_room=(fifo_level<=FIFO_SAFE_LEVEL)&&!fifo_full;
 wire [31:0] cluster_lba=data_start+((cluster-2)*spc);
 wire [31:0] entry_cluster={ent[21],ent[20],ent[27],ent[26]};
 wire [31:0] entry_size={sd_data,ent[30],ent[29],ent[28]};

 // Cross the read event into the SD clock domain and conservatively account
 // for FIFO occupancy.  SD produces at most 128 stereo frames per sector.
 always @(posedge clk or posedge rst) begin
  if(rst) begin read_meta<=0;read_sync<=0;read_seen<=0;fifo_level<=0;end
  else begin
   read_meta<=audio_read_toggle; read_sync<=read_meta;
   if(read_event) read_seen<=read_sync;
   case({fifo_we,read_event})
    2'b10:fifo_level<=fifo_level+1'b1;
    2'b01:if(fifo_level!=0)fifo_level<=fifo_level-1'b1;
    default:fifo_level<=fifo_level;
   endcase
  end
 end

 always @(posedge clk or posedge rst) begin
  if(rst) begin
   state<=IDLE;pos<=0;fat_offset<=0;sd_sec_read<=0;sd_sec_read_addr<=0;
   fifo_we<=0;fifo_din<=0;busy<=0;done<=0;file_found<=0;format_ok<=0;format_error<=0;
   part<=0;fat_start<=0;data_start<=0;root<=0;spf<=0;reserved<=0;spc<=0;fats<=0;
   first_cluster<=0;cluster<=0;sector<=0;file_size<=0;file_pos<=0;fat_next<=0;sector_in_cluster<=0;
   pcm_index<=0;p0<=0;p1<=0;p2<=0;wav_data_remaining<=0;
   header_pos<=0;
   chunk_id0<=0;chunk_id1<=0;chunk_id2<=0;chunk_id3<=0;
   chunk_size<=0;chunk_skip_remaining<=0;chunk_header_pos<=0;data_found<=0;
   format_error_pending<=0;
   for(i=0;i<32;i=i+1)ent[i]<=0;
   for(i=0;i<44;i=i+1)h[i]<=0;
  end else begin
   fifo_we<=0; done<=0;
   case(state)
    // Let the BMP catalogue and first SDRAM frame finish before WAV metadata
    // begins using the shared SD SPI bus.  This guarantees a visible HDMI
    // picture even if the WAV file is absent, fragmented, or malformed.
    IDLE:if(sd_init_done && enable)begin busy<=1;file_found<=0;format_ok<=0;pos<=0;sd_sec_read_addr<=0;sd_sec_read<=1;state<=MBR;end
    MBR:begin
     if(sd_data_valid)begin
      if(pos==454)part[7:0]<=sd_data;if(pos==455)part[15:8]<=sd_data;
      if(pos==456)part[23:16]<=sd_data;if(pos==457)part[31:24]<=sd_data;pos<=pos+1;
     end
     if(sd_sec_read_end)begin pos<=0;sd_sec_read_addr<=part;sd_sec_read<=1;state<=BPB;end
    end
    BPB:begin
     if(sd_data_valid)begin
      if(pos==13)spc<=sd_data;if(pos==14)reserved[7:0]<=sd_data;if(pos==15)reserved[15:8]<=sd_data;if(pos==16)fats<=sd_data;
      if(pos>=36&&pos<=39)spf[(pos-36)*8 +:8]<=sd_data;if(pos>=44&&pos<=47)root[(pos-44)*8 +:8]<=sd_data;pos<=pos+1;
     end
     if(sd_sec_read_end)begin
      pos<=0;fat_start<=part+reserved;data_start<=part+reserved+(fats*spf);
      // Root is a cluster number, so retain it for directory-chain walking.
      // The previous implementation only computed the first LBA and left
      // cluster at zero, which made the first ST_FAT lookup underflow and ended
      // the search with state 9 after one directory cluster.
      cluster<=root;
      sector_in_cluster<=0;
      sector<=part+reserved+(fats*spf)+((root-2)*spc);
      sd_sec_read_addr<=part+reserved+(fats*spf)+((root-2)*spc);sd_sec_read<=1;state<=DIR;
     end
    end
    DIR:begin
     if(sd_data_valid)begin
      ent[pos[4:0]]<=sd_data;pos<=pos+1;
      // Accept any regular 8.3 WAV file in the root directory.  Earlier
      // builds required the example alias WAN_CAN_.WAV, which silently
      // failed when the card contained music.wav or another valid name.
      if(pos[4:0]==31 && ent[8]=="W"&&ent[9]=="A"&&ent[10]=="V"&&
         ent[11]!=8'h0f&&ent[11]!=8'h10&&ent[11]!=8'h08&&ent[0]!=8'hE5)begin
       file_found<=1;first_cluster<=entry_cluster;cluster<=entry_cluster;
       sector<=data_start+((entry_cluster-2)*spc);file_size<=entry_size;file_pos<=0;sector_in_cluster<=0;
       header_pos<=0;pcm_index<=0;state<=DIR_FOUND;
      end
     end
     if(sd_sec_read_end && !file_found)begin
      sd_sec_read<=0;
      // The FAT32 root directory is a cluster chain. Continue through every
      // sector in the current cluster, then follow the ST_FAT entry when the
      // cluster boundary is reached. This avoids reporting state 9 merely
      // because the WAV entry is beyond the first 512-byte directory sector.
      if(sector_in_cluster+1<spc)begin
       sector_in_cluster<=sector_in_cluster+1;
       sector<=sector+1;
       sd_sec_read_addr<=sector+1;
       sd_sec_read<=1;
       state<=DIR;
      end else begin
       fat_offset<=cluster[6:0]<<2;
       pos<=0;
       sd_sec_read_addr<=fat_start+(cluster>>7);
       sd_sec_read<=1;
       state<=ST_DIR_FATDATA;
      end
     end
    end
    // The SD sector that contained the directory entry must finish before
    // the shared port can be reused for WAV data.
    DIR_FOUND:if(sd_sec_read_end)begin sd_sec_read<=0;state<=WAIT;end
    WAIT:if(fifo_room)begin sd_sec_read_addr<=sector;sd_sec_read<=1;state<=DATA;end
    DATA:begin
      if(sd_data_valid && file_pos<file_size)begin
       file_pos<=file_pos+1;
       if(header_pos<44)begin
        h[header_pos]<=sd_data;header_pos<=header_pos+1;
       if(header_pos==43)begin
        format_ok<=base_header_valid;
        format_error<=!base_header_valid;
        if (h[36]=="d"&&h[37]=="a"&&h[38]=="t"&&h[39]=="a") begin
         data_found<=1;
         wav_data_remaining<={sd_data,h[42],h[41],h[40]};
        end else begin
         // The first non-standard chunk header may already be inside the
         // initial 44-byte read (for example LIST at offsets 36..43).
         // Seed the chunk skipper with that header; subsequent bytes are its
         // payload and the next chunk header will be parsed normally.
         data_found<=0; wav_data_remaining<=0; chunk_header_pos<=0;
         chunk_id0<=h[36]; chunk_id1<=h[37]; chunk_id2<=h[38]; chunk_id3<=h[39];
         chunk_size<={sd_data,h[42],h[41],h[40]};
         chunk_skip_remaining<={sd_data,h[42],h[41],h[40]} +
                               ((({sd_data,h[42],h[41],h[40]}) & 32'd1)!=0);
        end
        // A malformed/unsupported WAV must not be scanned to EOF.  Keep the
        // current SD transaction alive until its sector-end pulse, then
        // release the arbiter so BMP requests (including key-driven changes)
        // can proceed immediately.
        format_error_pending<=!base_header_valid;
       end
       end
       else if(format_ok && !data_found)begin
         // WAV permits LIST/JUNK/fact and other chunks between fmt and data.
         // Consume each chunk's 4-byte ID and 32-bit little-endian length,
         // then skip its payload (including the optional odd-byte pad).
         if (chunk_skip_remaining!=0) begin
           chunk_skip_remaining<=chunk_skip_remaining-1;
         end else if (chunk_header_pos<8) begin
           case (chunk_header_pos)
             0: chunk_id0<=sd_data; 1: chunk_id1<=sd_data;
             2: chunk_id2<=sd_data; 3: chunk_id3<=sd_data;
             4: chunk_size[7:0]<=sd_data; 5: chunk_size[15:8]<=sd_data;
             6: chunk_size[23:16]<=sd_data;
             7: begin
               chunk_size[31:24]<=sd_data;
               if (chunk_id0=="d"&&chunk_id1=="a"&&chunk_id2=="t"&&chunk_id3=="a") begin
                 data_found<=1; wav_data_remaining<={sd_data,chunk_size[23:0]};
               end else begin
                 chunk_skip_remaining<={sd_data,chunk_size[23:0]} +
                                        ((({sd_data,chunk_size[23:0]}) & 32'd1)!=0);
               end
               chunk_header_pos<=0;
             end
           endcase
           if (chunk_header_pos<7) chunk_header_pos<=chunk_header_pos+1;
         end
       end else if(format_ok && wav_data_remaining!=0)begin
         case(pcm_index)0:p0<=sd_data;1:p1<=sd_data;2:p2<=sd_data;3:begin fifo_din<={sd_data,p2,p1,p0};fifo_we<=1;end endcase
         pcm_index<=pcm_index+1;wav_data_remaining<=wav_data_remaining-1;
      end
      end
     if(sd_sec_read_end)begin
      sd_sec_read<=0;
       if(format_error_pending)begin
       busy<=0; done<=1; format_error_pending<=0; state<=HOLD;
       end else if(file_pos+1>=file_size)begin
       // Repeat playback from the beginning after the file's declared size.
       cluster<=first_cluster;sector<=data_start+((first_cluster-2)*spc);file_pos<=0;sector_in_cluster<=0;
       header_pos<=0;pcm_index<=0;wav_data_remaining<=0;format_ok<=0;format_error_pending<=0;data_found<=0;chunk_skip_remaining<=0;chunk_header_pos<=0;done<=1;state<=WAIT;
      end else if(sector_in_cluster+1<spc)begin sector_in_cluster<=sector_in_cluster+1;sector<=sector+1;state<=WAIT;end
      else begin state<=ST_FAT;end
     end
    end
    ST_FAT:begin fat_offset<=cluster[6:0]<<2;pos<=0;sd_sec_read_addr<=fat_start+(cluster>>7);sd_sec_read<=1;state<=ST_FATDATA;end
    ST_FATDATA:begin
     if(sd_data_valid)begin
      if(pos==fat_offset)fat_next[7:0]<=sd_data;if(pos==fat_offset+1)fat_next[15:8]<=sd_data;
      if(pos==fat_offset+2)fat_next[23:16]<=sd_data;if(pos==fat_offset+3)fat_next[31:24]<=sd_data;pos<=pos+1;
     end
     if(sd_sec_read_end)begin
      sd_sec_read<=0;
      if(fat_next>=32'h0ffffff8||fat_next<2)begin
       cluster<=first_cluster;sector<=data_start+((first_cluster-2)*spc);file_pos<=0;sector_in_cluster<=0;
       header_pos<=0;pcm_index<=0;wav_data_remaining<=0;format_ok<=0;format_error_pending<=0;data_found<=0;chunk_skip_remaining<=0;chunk_header_pos<=0;done<=1;state<=WAIT;
      end else begin cluster<=fat_next&32'h0fffffff;sector<=data_start+(((fat_next&32'h0fffffff)-2)*spc);sector_in_cluster<=0;state<=WAIT;end
     end
    end
    ST_DIR_FATDATA:begin
     if(sd_data_valid)begin
      if(pos==fat_offset)fat_next[7:0]<=sd_data;
      if(pos==fat_offset+1)fat_next[15:8]<=sd_data;
      if(pos==fat_offset+2)fat_next[23:16]<=sd_data;
      if(pos==fat_offset+3)fat_next[31:24]<=sd_data;
      pos<=pos+1;
     end
     if(sd_sec_read_end)begin
      sd_sec_read<=0;
      if(fat_next>=32'h0ffffff8 || fat_next<2)begin
       busy<=0; done<=1; state<=HOLD;
      end else begin
       cluster<=fat_next&32'h0fffffff;
       sector<=data_start+(((fat_next&32'h0fffffff)-2)*spc);
       sector_in_cluster<=0;
       sd_sec_read_addr<=data_start+(((fat_next&32'h0fffffff)-2)*spc);
       sd_sec_read<=1;
       state<=DIR;
      end
     end
    end
    HOLD:begin end
    default:state<=IDLE;
   endcase
  end
 end
endmodule
