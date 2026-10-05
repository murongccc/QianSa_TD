// 共享 SD SPI 的规范 WAV 读取器，仅接受 44 字节头的 48 kHz/16 bit/双声道 PCM。
// 媒体模式读取根目录首个 WAV 并循环；游戏模式精确读取 GAME.WAV 并单次播放。
// fmt 必须为 16 字节且 data 紧随其后；不接受 LIST/JUNK、扩展 fmt 或尾随块。
// The producer reserves room for a whole sector before requesting it, so an
// unpausable SD sector never overflows the asynchronous audio FIFO.
module fat32_wav_reader #(
 parameter integer FIFO_SAFE_LEVEL=3968,
 parameter integer USE_SHARED_VOLUME=0,
 parameter integer ENABLE_GAME=0, parameter integer EXCLUDE_GAME_WAV=0
)(
 input wire clk,input wire rst,input wire sd_init_done,input wire enable,
 output reg sd_sec_read,output reg [31:0] sd_sec_read_addr,
 input wire [7:0] sd_data,input wire sd_data_valid,input wire sd_sec_read_end,
 output reg fifo_we,output reg [31:0] fifo_din,input wire fifo_full,
 input wire audio_read_toggle,
 output wire [31:0] audio_fifo_level,
 output reg busy,output reg done,output reg file_found,output reg format_ok,
 output reg format_error,
 // 板级复用已验证的卷；独立使用时默认保留原 MBR/BPB 解析接口。
 input wire volume_valid,
 input wire [31:0] volume_fat_start,volume_data_start,volume_root_cluster,
 input wire [7:0] volume_sectors_per_cluster,
 // 仅 ENABLE_GAME=1 时使用；game_mode 必须在开始前稳定并保持至会话结束。
 input wire game_mode, input wire cancel,
 output reg [31:0] song_frames, output reg song_frames_valid,
 output reg stream_eof, output reg cancelled
);
 localparam IDLE=0,MBR=1,BPB=2,DIR=3,DIR_FOUND=4,WAIT=5,DATA=6,ST_FAT=7,ST_FATDATA=8,HOLD=9,DIR_FAT=10,ST_DIR_FATDATA=11,
            CALC_OFFSET=12,CALC_SECTOR=13,BPB_CALC=14,CALC_MULTIPLY=15,DATA_END=16,FAT_END=17,DIR_FAT_END=18,DIR_END=19,FILE_SETUP=20,CALC_PRODUCT=21;
 localparam CALC_ROOT_DIR=2'd0,CALC_FIRST_FILE=2'd1,CALC_NEXT_FILE=2'd2,CALC_NEXT_DIR=2'd3;
 // 每个不可暂停扇区最多产生 128 个立体声帧；计数须能表示水位加整扇区。
 function integer fifo_count_width;
  input integer max_count;
  integer remaining;
  begin
   remaining=max_count; fifo_count_width=0;
   while(remaining>0)begin remaining=remaining>>1;fifo_count_width=fifo_count_width+1;end
   if(fifo_count_width<1)fifo_count_width=1;
  end
 endfunction
 localparam integer FIFO_LEVEL_WIDTH=fifo_count_width(FIFO_SAFE_LEVEL+128);
 localparam [FIFO_LEVEL_WIDTH-1:0] FIFO_SAFE_COUNT=FIFO_SAFE_LEVEL;
 reg [4:0] state; reg [8:0] pos,fat_offset; reg [7:0] entry_first,entry_attr;
 reg [23:0] entry_ext,entry_size_low;
 reg [31:0] entry_cluster;
 reg [31:0] part,fat_start,data_start,root,first_cluster,first_sector,cluster,sector,file_size,file_pos,fat_next;
 reg [7:0] boot_fat0,boot_fat1,boot_fat2,boot_fat3,boot_fat4;
 reg mbr_entry_is_fat,mbr_found_partition,mbr_writing_lba;
 reg [31:0] spf;
 reg [31:0] fat_sectors,cluster_offset;
 reg [1:0] calc_action;
 reg [31:0] cluster_product;
 reg [2:0] multiply_bit;
 reg [15:0] reserved; reg [7:0] spc,fats,sector_in_cluster;
 reg [FIFO_LEVEL_WIDTH-1:0] fifo_level; reg read_meta,read_sync,read_seen;
 reg [1:0] pcm_index; reg [7:0] p0,p1,p2;
 reg base_header_error; reg [5:0] header_pos;
 reg name_match, game_session, cancel_pending;
 reg [31:0] expected_length;
 reg game_dir_end;
 reg [15:0] game_dir_sectors;
 wire cancel_active=ENABLE_GAME && (cancel || cancel_pending);
 reg format_error_pending;
 // 固定头字段流式校验；错误标志在每次新 RIFF 头开始时重新清零。
 function header_byte_invalid;
  input [5:0] index; input [7:0] value;
  begin
   case(index)
    6'd0:header_byte_invalid=(value!="R");
    6'd1:header_byte_invalid=(value!="I");
    6'd2:header_byte_invalid=(value!="F");
    6'd3:header_byte_invalid=(value!="F");
    6'd4:header_byte_invalid=(value!=expected_length[7:0]);
    6'd5:header_byte_invalid=(value!=expected_length[15:8]);
    6'd6:header_byte_invalid=(value!=expected_length[23:16]);
    6'd7:header_byte_invalid=(value!=expected_length[31:24]);
    6'd8:header_byte_invalid=(value!="W");
    6'd9:header_byte_invalid=(value!="A");
    6'd10:header_byte_invalid=(value!="V");
    6'd11:header_byte_invalid=(value!="E");
    6'd12:header_byte_invalid=(value!="f");
    6'd13:header_byte_invalid=(value!="m");
    6'd14:header_byte_invalid=(value!="t");
    6'd15:header_byte_invalid=(value!=" ");
    6'd20:header_byte_invalid=(value!=8'd1);
    6'd21:header_byte_invalid=(value!=8'd0);
    6'd22:header_byte_invalid=(value!=8'd2);
    6'd23:header_byte_invalid=(value!=8'd0);
    6'd24:header_byte_invalid=(value!=8'h80);
    6'd25:header_byte_invalid=(value!=8'hbb);
    6'd26:header_byte_invalid=(value!=8'd0);
    6'd27:header_byte_invalid=(value!=8'd0);
    6'd34:header_byte_invalid=(value!=8'd16);
    6'd35:header_byte_invalid=(value!=8'd0);
    6'd16:header_byte_invalid=(value!=8'd16);
    6'd17,6'd18,6'd19:header_byte_invalid=(value!=8'd0);
    6'd28:header_byte_invalid=(value!=8'h00);
    6'd29:header_byte_invalid=(value!=8'hee);
    6'd30:header_byte_invalid=(value!=8'h02);
    6'd31:header_byte_invalid=(value!=8'd0);
    6'd32:header_byte_invalid=(value!=8'd4);
    6'd33:header_byte_invalid=(value!=8'd0);
    6'd36:header_byte_invalid=(value!="d");
    6'd37:header_byte_invalid=(value!="a");
    6'd38:header_byte_invalid=(value!="t");
    6'd39:header_byte_invalid=(value!="a");
    6'd40:header_byte_invalid=(value!=expected_length[7:0]);
    6'd41:header_byte_invalid=(value!=expected_length[15:8]);
    6'd42:header_byte_invalid=(value!=expected_length[23:16]);
    6'd43:header_byte_invalid=(value!=expected_length[31:24]);
    default:header_byte_invalid=1'b0;
   endcase
  end
 endfunction
 // 长度在目录事务结束后预计算，并逐字节检查，避免头末拍的宽减法/比较链。
 // 43 是当前输入的长度高字节，仍须检查当前值；其余字段已累计到错误标志。
 wire canonical_header_valid=!base_header_error && expected_length[1:0]==2'b00 &&
                             sd_data==expected_length[31:24];
 // 八轮乘法（含任意 8 位 spc）显式共用一个加法器。
 wire [31:0] multiply_sum=cluster_product+(spc[multiply_bit]?cluster_offset:32'd0);
 wire read_event=read_sync!=read_seen;
 // 同一个加法器实现 +1/-1；减一用计数位宽内的全一补码。
 wire [FIFO_LEVEL_WIDTH-1:0] fifo_count_delta={{(FIFO_LEVEL_WIDTH-1){!fifo_we}},1'b1};
 wire fifo_room=(fifo_level<=FIFO_SAFE_COUNT)&&!fifo_full;
 wire [31:0] entry_size={sd_data,entry_size_low};
 // 保留外部 32 位接口，内部无符号计数自动零扩展。
 assign audio_fifo_level = fifo_level;

 // Cross the read event into the SD clock domain and conservatively account
 // for FIFO occupancy.  SD produces at most 128 stereo frames per sector.
 always @(posedge clk or posedge rst) begin
  if(rst) begin read_meta<=0;read_sync<=0;read_seen<=0;fifo_level<=0;end
  else begin
   read_meta<=audio_read_toggle; read_sync<=read_meta;
   if(read_event) read_seen<=read_sync;
   case({fifo_we,read_event})
    2'b10,2'b01:if(fifo_we || fifo_level!=0)fifo_level<=fifo_level+fifo_count_delta;
    default:fifo_level<=fifo_level;
   endcase
  end
 end

 always @(posedge clk or posedge rst) begin
  if(rst) begin
   state<=IDLE;pos<=0;fat_offset<=0;sd_sec_read<=0;sd_sec_read_addr<=0;
   fifo_we<=0;fifo_din<=0;busy<=0;done<=0;file_found<=0;format_ok<=0;format_error<=0;
   part<=0;fat_start<=0;data_start<=0;root<=0;spf<=0;fat_sectors<=0;cluster_offset<=0;calc_action<=0;reserved<=0;spc<=0;fats<=0;
   boot_fat0<=0;boot_fat1<=0;boot_fat2<=0;boot_fat3<=0;boot_fat4<=0;
   mbr_entry_is_fat<=0;mbr_found_partition<=0;mbr_writing_lba<=0;
   first_cluster<=0;first_sector<=0;cluster<=0;sector<=0;file_size<=0;file_pos<=0;fat_next<=0;sector_in_cluster<=0;
   pcm_index<=0;p0<=0;p1<=0;p2<=0;
   header_pos<=0;cluster_product<=0;multiply_bit<=0;
   format_error_pending<=0;
   entry_first<=0;entry_attr<=0;entry_ext<=0;entry_size_low<=0;entry_cluster<=0;
   base_header_error<=0;
   name_match<=0;game_session<=0;cancel_pending<=0;cancelled<=0;
   song_frames<=0;song_frames_valid<=0;stream_eof<=0;expected_length<=0;
   game_dir_end<=0;game_dir_sectors<=0;
  end else begin
   fifo_we<=0; done<=0;
   // 取消不打断已经获准的整扇区：保持请求/地址到 done，再允许外部清 FIFO/复位。
   if(cancel_active)begin
    cancel_pending<=1'b1;
    if(!sd_sec_read || sd_sec_read_end)begin
     sd_sec_read<=0;busy<=0;done<=!cancelled;cancelled<=1;state<=HOLD;
    end
   end else case(state)
    // Let the BMP catalogue and first SDRAM frame finish before WAV metadata
    // begins using the shared SD SPI bus.  This guarantees a visible HDMI
    // picture even if the WAV file is absent, fragmented, or malformed.
    IDLE:if(sd_init_done && enable)begin
     busy<=1;file_found<=0;format_ok<=0;pos<=0;part<=0;
     game_session<=ENABLE_GAME && game_mode;
     mbr_entry_is_fat<=0;mbr_found_partition<=0;mbr_writing_lba<=0;
     boot_fat0<=0;boot_fat1<=0;boot_fat2<=0;boot_fat3<=0;boot_fat4<=0;
     if(USE_SHARED_VOLUME)begin
      if(volume_valid)begin
       fat_start<=volume_fat_start;data_start<=volume_data_start;
       spc<=volume_sectors_per_cluster;cluster<=volume_root_cluster;
       sector_in_cluster<=0;calc_action<=CALC_ROOT_DIR;
       sd_sec_read<=0;state<=CALC_OFFSET;
      end else begin
       sd_sec_read<=0;busy<=0;done<=1;state<=HOLD;
      end
     end else begin sd_sec_read_addr<=0;sd_sec_read<=1;state<=MBR;end
    end
    MBR:if(!USE_SHARED_VOLUME)begin
     if(sd_data_valid)begin
      // MBR 中选择物理顺序最靠前的 FAT32 主分区，而不是盲目使用第一个分区。
      if(pos==450||pos==466||pos==482||pos==498)
       mbr_entry_is_fat<=(sd_data==8'h0b||sd_data==8'h0c);
      if((pos==454||pos==470||pos==486||pos==502)&&mbr_entry_is_fat&&!mbr_found_partition)begin
       part[7:0]<=sd_data;mbr_found_partition<=1;mbr_writing_lba<=1;
      end else if(mbr_writing_lba&&(pos==455||pos==471||pos==487||pos==503))begin
       part[15:8]<=sd_data;
      end else if(mbr_writing_lba&&(pos==456||pos==472||pos==488||pos==504))begin
       part[23:16]<=sd_data;
      end else if(mbr_writing_lba&&(pos==457||pos==473||pos==489||pos==505))begin
       part[31:24]<=sd_data;mbr_writing_lba<=0;
      end
      pos<=pos+1;
      if(pos==82)boot_fat0<=sd_data;if(pos==83)boot_fat1<=sd_data;
      if(pos==84)boot_fat2<=sd_data;if(pos==85)boot_fat3<=sd_data;if(pos==86)boot_fat4<=sd_data;
     end
     if(sd_sec_read_end)begin
      pos<=0;
      // FAT32 引导扇区直接位于 LBA0（superfloppy）时不经过 MBR 分区项。
      if(boot_fat0=="F"&&boot_fat1=="A"&&boot_fat2=="T"&&boot_fat3=="3"&&boot_fat4=="2") begin
       part<=0;sd_sec_read_addr<=0;sd_sec_read<=1;state<=BPB;
      end else if(mbr_found_partition) begin
       sd_sec_read_addr<=part;sd_sec_read<=1;state<=BPB;
      end else begin
       busy<=0;done<=1;state<=HOLD;
      end
     end
    end
    BPB:if(!USE_SHARED_VOLUME)begin
     if(sd_data_valid)begin
      if(pos==13)spc<=sd_data;if(pos==14)reserved[7:0]<=sd_data;if(pos==15)reserved[15:8]<=sd_data;if(pos==16)fats<=sd_data;
      if(pos>=36&&pos<=39)spf[(pos-36)*8 +:8]<=sd_data;if(pos>=44&&pos<=47)root[(pos-44)*8 +:8]<=sd_data;pos<=pos+1;
     end
     if(sd_sec_read_end)begin
      pos<=0;sd_sec_read<=0;fat_start<=part+reserved;fat_sectors<=fats*spf;
      // Root is a cluster number, so retain it for directory-chain walking.
      // The previous implementation only computed the first LBA and left
      // cluster at zero, which made the first ST_FAT lookup underflow and ended
      // the search with state 9 after one directory cluster.
      cluster<=root;sector_in_cluster<=0;calc_action<=CALC_ROOT_DIR;state<=BPB_CALC;
     end
    end
    DIR:begin
     if(sd_data_valid)begin
      // 每个目录项的必要字段都有固定写入位置，非连续字节也不会错位。
      case(pos[4:0])
          5'd0: begin entry_first<=sd_data;name_match<=(sd_data=="G");if(game_session && sd_data==0)game_dir_end<=1;end
          5'd1: name_match<=name_match && sd_data=="A";
          5'd2: name_match<=name_match && sd_data=="M";
          5'd3: name_match<=name_match && sd_data=="E";
          5'd4,5'd5,5'd6,5'd7: name_match<=name_match && sd_data==" ";
          5'd8: entry_ext[7:0]<=sd_data;
          5'd9: entry_ext[15:8]<=sd_data;
          5'd10: entry_ext[23:16]<=sd_data;
          5'd11: entry_attr<=sd_data;
          5'd20: entry_cluster[23:16]<=sd_data;
          5'd21: entry_cluster[31:24]<=sd_data;
          5'd26: entry_cluster[7:0]<=sd_data;
          5'd27: entry_cluster[15:8]<=sd_data;
          5'd28: entry_size_low[7:0]<=sd_data;
          5'd29: entry_size_low[15:8]<=sd_data;
          5'd30: entry_size_low[23:16]<=sd_data;
          default: ;
      endcase
      pos<=pos+1;
      // 所有目录项末字节先暂存完整描述符，复杂格式判断只发布命中标志。
      // 命中后退出 DIR，因此不会被后续目录项覆盖。
      if(pos[4:0]==5'd31)begin first_cluster<=entry_cluster;file_size<=entry_size;end
      // Accept any regular 8.3 WAV file in the root directory.  Earlier
      // builds required the example alias WAN_CAN_.WAV, which silently
      // failed when the card contained music.wav or another valid name.
      if(pos[4:0]==31 && entry_ext[7:0]=="W"&&entry_ext[15:8]=="A"&&entry_ext[23:16]=="V"&&
         (game_session ? (name_match && !game_dir_end) : !(EXCLUDE_GAME_WAV && name_match)) &&
         entry_attr!=8'h0f&&((entry_attr&8'h18)==0)&&entry_first!=8'hE5&&entry_first!=0)begin
       file_found<=1;state<=DIR_FOUND;
      end
     end
     if(sd_sec_read_end)begin sd_sec_read<=0;state<=DIR_END;end
    end
    DIR_END:begin
     if(file_found)state<=FILE_SETUP;
     else begin
      game_dir_sectors<=game_dir_sectors+16'd1;
      // The FAT32 root directory is a cluster chain. Continue through every
      // sector in the current cluster, then follow the ST_FAT entry when the
      // cluster boundary is reached. This avoids reporting state 9 merely
      // because the WAV entry is beyond the first 512-byte directory sector.
      if(game_session && (game_dir_end || game_dir_sectors>=16'd1023))begin
       busy<=0;done<=1;state<=HOLD;
      end else if(sector_in_cluster+1<spc)begin
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
    DIR_FOUND:if(sd_sec_read_end)begin sd_sec_read<=0;state<=FILE_SETUP;end
    FILE_SETUP:begin
     header_pos<=0;pcm_index<=0;file_pos<=0;sector_in_cluster<=0;
     calc_action<=CALC_FIRST_FILE;state<=CALC_OFFSET;
     // 目录事务结束后预计算 RIFF 长度，校验完成后复用为 data 长度。
     expected_length<=file_size-32'd8;
     cluster<=first_cluster & 32'h0fffffff;first_cluster<=first_cluster & 32'h0fffffff;
     // 最小有效文件包含 44 字节头和一个完整的 4 字节立体声采样帧。
     if((first_cluster & 32'h0fffffff)<32'd2 || (first_cluster & 32'h0fffffff)>=32'h0ffffff0 || file_size<32'd48)begin
      format_error<=1;busy<=0;done<=1;state<=HOLD;
     end
    end
    WAIT:if(fifo_room)begin sd_sec_read_addr<=sector;sd_sec_read<=1;state<=DATA;end
    DATA:begin
      // FILE_SETUP 已拒绝小于 48 字节的文件，头偏移 43 的字节必在文件内。
      // 头位置只递增到 44；格式结果不再经过逐字节的 32 位文件边界比较。
      if(sd_data_valid && header_pos==6'd43)begin
       format_ok<=canonical_header_valid;
       format_error<=!canonical_header_valid;
       // 错误后仍排空已接受的整扇区，再释放仲裁器；期间不发布 PCM。
       format_error_pending<=!canonical_header_valid;
       if(game_session && canonical_header_valid)begin
        song_frames<={2'd0,expected_length[31:2]};song_frames_valid<=1;
       end
      end
      if(sd_data_valid && file_pos<file_size)begin
       file_pos<=file_pos+1;
       if(header_pos<44)begin
        // 固定字段与两个完整 32 位长度都逐字节校验，不保存输入图头。
        if(header_pos==0) base_header_error<=header_byte_invalid(header_pos,sd_data);
        else if(header_byte_invalid(header_pos,sd_data)) base_header_error<=1'b1;
        header_pos<=header_pos+1;
        // RIFF 长度已经校验完，复用同一寄存器计算 data 长度。
        if(header_pos==6'd8)expected_length<=file_size-32'd44;
       end
       // 规范 data 恰好覆盖 [44,file_size)，外层 file_pos 边界即可限制 PCM。
       // 无需再维护与文件位置重复的 32 位 data 剩余计数器。
       else if(format_ok)begin
         case(pcm_index)0:p0<=sd_data;1:p1<=sd_data;2:p2<=sd_data;3:begin fifo_din<={sd_data,p2,p1,p0};fifo_we<=1;end endcase
         pcm_index<=pcm_index+1;
      end
      end
     if(sd_sec_read_end)begin
      sd_sec_read<=0;state<=DATA_END;
     end
    end
    DATA_END:begin
       // 在 done 下一拍检查，包含末字节同拍更新的头错误、文件位置和 PCM 相位。
       // 切断 SD 返回数据经头校验直接驱动扇区地址使能的组合路径。
       if(format_error_pending)begin
       busy<=0; done<=1; format_error_pending<=0; state<=HOLD;
       end else if(file_pos>=file_size)begin
       // Repeat playback from the beginning after the file's declared size.
       cluster<=first_cluster;sector<=first_sector;file_pos<=0;sector_in_cluster<=0;
       header_pos<=0;pcm_index<=0;format_error_pending<=0;done<=1;expected_length<=file_size-32'd8;
       if(!format_ok || pcm_index!=2'd0 ||
          (game_session && !song_frames_valid))begin
        busy<=0;format_ok<=0;format_error<=1;state<=HOLD;
       end else if(game_session)begin busy<=0;stream_eof<=1;state<=HOLD;end
       else begin format_ok<=0;state<=WAIT;end
      end else if(sector_in_cluster+1<spc)begin sector_in_cluster<=sector_in_cluster+1;sector<=sector+1;state<=WAIT;end
      else begin state<=ST_FAT;end
    end
    ST_FAT:begin fat_offset<=cluster[6:0]<<2;pos<=0;sd_sec_read_addr<=fat_start+(cluster>>7);sd_sec_read<=1;state<=ST_FATDATA;end
    ST_FATDATA:begin
     if(sd_data_valid)begin
      if(pos==fat_offset)fat_next[7:0]<=sd_data;if(pos==fat_offset+1)fat_next[15:8]<=sd_data;
      if(pos==fat_offset+2)fat_next[23:16]<=sd_data;if(pos==fat_offset+3)fat_next[31:24]<=sd_data;pos<=pos+1;
     end
     if(sd_sec_read_end)begin sd_sec_read<=0;state<=FAT_END;end
    end
    FAT_END:begin
      if((fat_next&32'h0fffffff)>=32'h0ffffff8||(fat_next&32'h0fffffff)<2 ||
         (fat_next&32'h0fffffff)>=32'h0ffffff0)begin
       // 文件尚未到 EOF 却遇到簇链结束，媒体和游戏都报截断，不循环错误文件。
       sd_sec_read<=0;busy<=0;format_ok<=0;format_error<=1;done<=1;state<=HOLD;
      end else begin cluster<=fat_next&32'h0fffffff;sector_in_cluster<=0;calc_action<=CALC_NEXT_FILE;state<=CALC_OFFSET;end
    end
    ST_DIR_FATDATA:begin
     if(sd_data_valid)begin
      if(pos==fat_offset)fat_next[7:0]<=sd_data;
      if(pos==fat_offset+1)fat_next[15:8]<=sd_data;
      if(pos==fat_offset+2)fat_next[23:16]<=sd_data;
      if(pos==fat_offset+3)fat_next[31:24]<=sd_data;
      pos<=pos+1;
     end
     if(sd_sec_read_end)begin sd_sec_read<=0;state<=DIR_FAT_END;end
    end
    DIR_FAT_END:begin
      if((fat_next&32'h0fffffff)>=32'h0ffffff8 || (fat_next&32'h0fffffff)<2 ||
         (game_session && (fat_next&32'h0fffffff)>=32'h0ffffff0))begin
       busy<=0; done<=1; state<=HOLD;
      end else begin
       cluster<=fat_next&32'h0fffffff;sector_in_cluster<=0;
       calc_action<=CALC_NEXT_DIR;state<=CALC_OFFSET;
      end
     end
    BPB_CALC:if(!USE_SHARED_VOLUME)begin
     data_start<=fat_start+fat_sectors;
     state<=CALC_OFFSET;
    end
    CALC_OFFSET:begin
     // 扇区请求之间有充足计算时间；8 拍移位加法保留任意 spc 的旧数学结果。
     cluster_offset<=cluster-32'd2;cluster_product<=0;multiply_bit<=0;
     state<=CALC_MULTIPLY;
    end
    CALC_MULTIPLY:begin
     // 八拍均只更新累加寄存器，最后结果另拍转移，避免位选择/加法直通偏移选择。
     cluster_product<=multiply_sum;
     if(multiply_bit==3'd7)state<=CALC_PRODUCT;
     else begin
      cluster_offset<={cluster_offset[30:0],1'b0};multiply_bit<=multiply_bit+3'd1;
     end
    end
    CALC_PRODUCT:begin
     cluster_offset<=cluster_product;
     state<=CALC_SECTOR;
    end
    CALC_SECTOR:begin
     sector<=data_start+cluster_offset;
     case(calc_action)
      CALC_ROOT_DIR,CALC_NEXT_DIR:begin
       sd_sec_read_addr<=data_start+cluster_offset;sd_sec_read<=1;state<=DIR;
      end
      CALC_FIRST_FILE:begin first_sector<=data_start+cluster_offset;state<=WAIT;end
      default:state<=WAIT;
     endcase
    end
    HOLD:begin end
    default:state<=IDLE;
   endcase
  end
 end
endmodule
