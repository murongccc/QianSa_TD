// FAT32 根目录 BMP 候选器。
// 根目录先完整扫描并缓存前五个候选，再按物理顺序逐个输出。这样目录
// 读取不再被 BMP 加载暂停，避免在真实 SD 卡上反复读同一目录扇区时丢项。
module fat32_bmp_catalog(
    input wire clk, input wire rst, input wire sd_init_done,
    output reg sd_sec_read, output reg [31:0] sd_sec_read_addr,
    input wire sd_sec_read_data_valid, input wire [7:0] sd_sec_read_data,
    input wire sd_sec_read_end,
    output reg candidate_valid, output reg [31:0] candidate_first_cluster,
    output reg [31:0] candidate_file_size,
    output reg [31:0] fat_start_sector, output reg [31:0] first_data_sector,
    output reg [7:0] sectors_per_cluster,
    // 已交给 BMP 读取器的候选数量，用于板级区分目录枚举与加载失败。
    output reg [2:0] candidate_count,
    input wire candidate_release, input wire stop,
    output reg scan_done, output reg volume_valid,
    output wire [31:0] volume_root_cluster
);
localparam ST_IDLE=4'd0, ST_MBR=4'd1, ST_BPB=4'd2, ST_SETUP=4'd3,
           ST_DIR_CALC=4'd4, ST_DIR=4'd5, ST_DIR_FAT=4'd6,
           ST_WAIT_CANDIDATE=4'd7, ST_HOLD=4'd8,
           ST_DIR_OFFSET=4'd9, ST_DIR_ADDR=4'd10,
           ST_DIR_FAT_CHECK=4'd11, ST_DIR_FAT_ADDR=4'd12,
           ST_EMIT_CANDIDATE=4'd13, ST_NEXT_CANDIDATE=4'd14,
           // 将引导扇区结束与字段有效性判断拆开，避免 BPB 寄存器的
           // 组合判断直接驱动下一扇区地址寄存器的写使能。
           ST_VALIDATE_BPB=4'd15;
localparam ST_DIR_END=5'd16, ST_FAT_CAPTURE=5'd17,
           ST_CACHE_PREFETCH=5'd18, ST_CACHE_READ=5'd19;
reg [4:0] state;
reg [9:0] pos;
// 仅用于过滤的字节在原捕获拍转为标志，完整簇号/文件长度继续保存。
reg entry_end,entry_deleted,entry_attr_excluded;
reg [2:0] entry_ext_ok;
reg [23:0] entry_size_low;
reg [31:0] entry_cluster;
reg sector_low_ok,sector_high_ok;
reg [15:0] reserved_sector_count;
reg [7:0] fat_count;
reg [31:0] sectors_per_fat, root_cluster, volume_base;
// 卷信息在初始化后保持稳定，供同一 SD 域的 WAV 读取器复用。
assign volume_root_cluster=root_cluster;
reg [31:0] mbr_partition_lba;
reg mbr_entry_is_fat, mbr_found_partition, mbr_writing_lba;
// 0：刚读完 LBA0，可在 BPB 无效时回退到 MBR 分区；
// 1：刚读完 MBR 指向的 BPB，校验失败即结束扫描。
reg validate_from_mbr;
reg [31:0] dir_cluster, dir_sector;
reg [31:0] dir_cluster_offset, dir_fat_sector_offset;
reg [7:0] dir_sector_in_cluster, dir_shift_spc;
reg [2:0] candidate_output_index;
reg dir_end_pending;
// 每个描述符四个 16 位字；缓存内容不复位，计数隔离上次会话的旧数据。
reg [63:0] cache_write_shift;
reg [2:0] cache_write_slot;
reg [1:0] cache_write_word, cache_read_word;
reg cache_write_busy;
wire [15:0] cache_read_data;
wire dir_entry_is_bmp;
wire [1:0] cache_read_next=(state==ST_CACHE_READ)?cache_read_word+2'd1:cache_read_word;
wire cache_accept=state==ST_DIR && sd_sec_read_data_valid && pos[4:0]==5'd31 &&
                  !dir_end_pending && dir_entry_is_bmp && candidate_count<3'd5;
// 候选计数另拍消费命中脉冲，避免目录宽判断再串计数进位。
reg cache_accept_q;
always @(posedge clk or posedge rst)begin
    if(rst)cache_accept_q<=0;
    else cache_accept_q<=cache_accept;
end
rhythm_block_ram #(.IMPLEMENT("9K"),.WIDTH(16),.ADDRESS_BITS(5),.DEPTH(32)) descriptor_cache(
    .write_clk(clk),.write_enable(cache_write_busy && !rst),
    .write_address({cache_write_slot,cache_write_word}),.write_data(cache_write_shift[15:0]),
    .read_clk(clk),.read_address({candidate_output_index,cache_read_next}),.read_data(cache_read_data));
// 接受目录项最少相隔 32 个字节，四拍写入不会阻塞连续的 SD 字节流。
// 四个字的描述符只在完整目录项装载后写 RAM；空闲时的数据不被消费。
// 去掉 64 位移位暂存的复位和保持使能，写使能/写索引仍由原控制复位。
always @(posedge clk)begin
    if(state==ST_DIR && sd_sec_read_data_valid && pos[4:0]==5'd31)begin
        cache_write_shift<={sd_sec_read_data,entry_size_low,entry_cluster};
        cache_write_slot<=candidate_count;
    end else cache_write_shift<={16'd0,cache_write_shift[63:16]};
end
always @(posedge clk or posedge rst) begin
    if(rst)begin cache_write_word<=0;cache_write_busy<=0;end
    else begin
      if(cache_accept)begin cache_write_word<=0;cache_write_busy<=1;end
      else if(cache_write_busy)begin
        if(cache_write_word==2'd3)cache_write_busy<=0;
        else cache_write_word<=cache_write_word+2'd1;
      end
    end
end
reg [8:0] fat_offset;
reg [31:0] fat_entry_shift;
reg [31:0] fat_next_cluster_reg;

// FAT 项按四字节对齐。四拍共享同一个写使能，避免独立字节使能
// 被打包到同一 slice 后争用局部控制布线；最后得到小端 32 位簇号。
wire fat_entry_byte_valid = (pos[9:2] == {1'b0,fat_offset[8:2]});

wire bpb_looks_valid = sector_low_ok && sector_high_ok &&
                       (sectors_per_cluster != 8'd0) &&
                       (fat_count != 8'd0) && (sectors_per_fat != 32'd0) &&
                       (root_cluster >= 32'd2);
assign dir_entry_is_bmp = !entry_end && !entry_deleted && !entry_attr_excluded &&
                        (&entry_ext_ok) &&
                        (entry_cluster >= 32'd2) &&
                        ({sd_sec_read_data,entry_size_low} != 32'd0);

task advance_directory_sector;
    begin
        pos <= 10'd0;
        if (dir_sector_in_cluster + 1'b1 < sectors_per_cluster) begin
            dir_sector_in_cluster <= dir_sector_in_cluster + 1'b1;
            dir_sector <= dir_sector + 1'b1;
            sd_sec_read_addr <= dir_sector + 1'b1;
            sd_sec_read <= 1'b1;
            state <= ST_DIR;
        end else begin
            fat_offset <= {dir_cluster[6:0],2'b00};
            dir_fat_sector_offset <= dir_cluster >> 7;
            sd_sec_read <= 1'b0;
            state <= ST_DIR_FAT_ADDR;
        end
    end
endtask

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state<=ST_IDLE; pos<=0; sd_sec_read<=0; sd_sec_read_addr<=0;
        candidate_valid<=0; candidate_first_cluster<=0; candidate_file_size<=0;
        fat_start_sector<=0; first_data_sector<=0; sectors_per_cluster<=0;
        candidate_count<=0;
        // 原 bytes_per_sector 复位为 0000：低字节匹配，高字节不匹配。
        scan_done<=0; volume_valid<=0; sector_low_ok<=1; sector_high_ok<=0; reserved_sector_count<=0;
        fat_count<=0; sectors_per_fat<=0; root_cluster<=0; volume_base<=0;
        mbr_partition_lba<=0; mbr_entry_is_fat<=0; mbr_found_partition<=0; mbr_writing_lba<=0;
        validate_from_mbr<=1'b0;
        dir_cluster<=0; dir_sector<=0; dir_cluster_offset<=0;
        dir_shift_spc<=0; dir_fat_sector_offset<=0;
        dir_sector_in_cluster<=0; candidate_output_index<=0; dir_end_pending<=0;
        fat_offset<=0; fat_entry_shift<=0;
        fat_next_cluster_reg<=0;
        entry_end<=1;entry_deleted<=0;entry_attr_excluded<=0;entry_ext_ok<=0;entry_size_low<=0;entry_cluster<=0;
        cache_read_word<=0;
    end else begin
        if(cache_accept_q)candidate_count<=candidate_count+3'd1;
        // LBA0 与分区 BPB 使用同一捕获路径，MBR 分区项解析保持独立。
        // 固定字节写入保持小端组装，末字节与 done 同拍仍先捕获后校验。
        if ((state==ST_MBR || state==ST_BPB) && sd_sec_read_data_valid) begin
            case(pos)
                10'd11: sector_low_ok<=sd_sec_read_data==8'd0;
                10'd12: sector_high_ok<=sd_sec_read_data==8'd2;
                10'd13: sectors_per_cluster<=sd_sec_read_data;
                10'd14: reserved_sector_count[7:0]<=sd_sec_read_data;
                10'd15: reserved_sector_count[15:8]<=sd_sec_read_data;
                10'd16: fat_count<=sd_sec_read_data;
                10'd36: sectors_per_fat[7:0]<=sd_sec_read_data;
                10'd37: sectors_per_fat[15:8]<=sd_sec_read_data;
                10'd38: sectors_per_fat[23:16]<=sd_sec_read_data;
                10'd39: sectors_per_fat[31:24]<=sd_sec_read_data;
                10'd44: root_cluster[7:0]<=sd_sec_read_data;
                10'd45: root_cluster[15:8]<=sd_sec_read_data;
                10'd46: root_cluster[23:16]<=sd_sec_read_data;
                10'd47: root_cluster[31:24]<=sd_sec_read_data;
                default: ;
            endcase
        end
        case (state)
            ST_IDLE: if (sd_init_done) begin
                scan_done<=0; volume_valid<=0; candidate_valid<=0;
                candidate_count<=0;
                candidate_output_index<=0; dir_end_pending<=0;
                pos<=0; sd_sec_read_addr<=32'd0; sd_sec_read<=1'b1; state<=ST_MBR;
            end
            // LBA0 同时检查为直接 FAT32 引导扇区或 MBR。
            ST_MBR: begin
                if (sd_sec_read_data_valid) begin
                    // 扫描四个主分区，选择第一个 FAT32 (0x0b/0x0c) 分区。
                    if (pos==10'd450 || pos==10'd466 || pos==10'd482 || pos==10'd498)
                        mbr_entry_is_fat <= (sd_sec_read_data==8'h0b || sd_sec_read_data==8'h0c);
                    if ((pos==10'd454 || pos==10'd470 || pos==10'd486 || pos==10'd502) &&
                        mbr_entry_is_fat && !mbr_found_partition) begin
                        mbr_partition_lba[7:0] <= sd_sec_read_data;
                        mbr_found_partition <= 1'b1;
                        mbr_writing_lba <= 1'b1;
                    end else if (mbr_writing_lba &&
                        (pos==10'd455 || pos==10'd471 || pos==10'd487 || pos==10'd503)) begin
                        mbr_partition_lba[15:8] <= sd_sec_read_data;
                    end else if (mbr_writing_lba &&
                        (pos==10'd456 || pos==10'd472 || pos==10'd488 || pos==10'd504)) begin
                        mbr_partition_lba[23:16] <= sd_sec_read_data;
                    end else if (mbr_writing_lba &&
                        (pos==10'd457 || pos==10'd473 || pos==10'd489 || pos==10'd505)) begin
                        mbr_partition_lba[31:24] <= sd_sec_read_data;
                        mbr_writing_lba <= 1'b0;
                    end
                    pos<=pos+1'b1;
                end
                if (sd_sec_read_end) begin
                    sd_sec_read<=0; pos<=0;
                    validate_from_mbr<=1'b0;
                    state<=ST_VALIDATE_BPB;
                end
            end
            ST_BPB: begin
                if (sd_sec_read_data_valid) begin
                    pos<=pos+1'b1;
                end
                if (sd_sec_read_end) begin
                    sd_sec_read<=0; pos<=0;
                    validate_from_mbr<=1'b1;
                    state<=ST_VALIDATE_BPB;
                end
            end
            // BPB 字段在前一拍已全部稳定。本拍再决定是否把 LBA0 当作
            // 直接 FAT32 引导扇区，或读取 MBR 所指向的分区引导扇区。
            ST_VALIDATE_BPB: begin
                if (bpb_looks_valid) begin
                    if (!validate_from_mbr)
                        volume_base<=32'd0;
                    state<=ST_SETUP;
                end else if (!validate_from_mbr && mbr_found_partition) begin
                    volume_base<=mbr_partition_lba;
                    sd_sec_read_addr<=mbr_partition_lba;
                    sd_sec_read<=1'b1;
                    state<=ST_BPB;
                end else begin
                    scan_done<=1'b1;
                    state<=ST_HOLD;
                end
            end
            ST_SETUP: begin
                fat_start_sector <= volume_base + reserved_sector_count;
                first_data_sector <= volume_base + reserved_sector_count + (fat_count * sectors_per_fat);
                dir_cluster <= root_cluster;
                dir_sector_in_cluster <= 0;
                volume_valid <= 1'b1;
                state <= ST_DIR_CALC;
            end
            ST_DIR_CALC: begin
                // 目录簇号先寄存减法结果，避免 dir_cluster 经过可变乘法
                // 和数据区加法后在同一拍直接驱动 SD 地址。
                if (dir_cluster < 32'd2) begin
                    scan_done<=1'b1; state<=ST_HOLD;
                end else begin
                    dir_cluster_offset<=dir_cluster-32'd2;dir_shift_spc<=sectors_per_cluster;
                    state<=ST_DIR_OFFSET;
                end
            end
            ST_DIR_OFFSET: begin
                // 同一工作寄存器逐拍左移，避免八种 32 位移位结果的选择器。
                case(dir_shift_spc)
                    8'd1:state<=ST_DIR_ADDR;
                    8'd2,8'd4,8'd8,8'd16,8'd32,8'd64,8'd128:begin
                        dir_cluster_offset<={dir_cluster_offset[30:0],1'b0};
                        dir_shift_spc<={1'b0,dir_shift_spc[7:1]};
                    end
                    default:begin scan_done<=1;state<=ST_HOLD;end
                endcase
            end
            ST_DIR_ADDR: begin
                dir_sector<=first_data_sector+dir_cluster_offset;
                sd_sec_read_addr<=first_data_sector+dir_cluster_offset;
                sd_sec_read<=1'b1;
                pos<=0;
                state<=ST_DIR;
            end
            ST_DIR: begin
                if (sd_sec_read_data_valid) begin
                    // 每个目录项的必要字段都有固定写入位置，非连续字节也不会错位。
                    case(pos[4:0])
                        5'd0: begin entry_end<=sd_sec_read_data==8'h00;entry_deleted<=sd_sec_read_data==8'he5;end
                        5'd8: entry_ext_ok[0]<=sd_sec_read_data=="B";
                        5'd9: entry_ext_ok[1]<=sd_sec_read_data=="M";
                        5'd10: entry_ext_ok[2]<=sd_sec_read_data=="P";
                        5'd11: entry_attr_excluded<=sd_sec_read_data==8'h0f || sd_sec_read_data==8'h10 || sd_sec_read_data==8'h08;
                        5'd20: entry_cluster[23:16]<=sd_sec_read_data;
                        5'd21: entry_cluster[31:24]<=sd_sec_read_data;
                        5'd26: entry_cluster[7:0]<=sd_sec_read_data;
                        5'd27: entry_cluster[15:8]<=sd_sec_read_data;
                        5'd28: entry_size_low[7:0]<=sd_sec_read_data;
                        5'd29: entry_size_low[15:8]<=sd_sec_read_data;
                        5'd30: entry_size_low[23:16]<=sd_sec_read_data;
                        default: ;
                    endcase
                    if (pos[4:0] == 5'd31) begin
                        if (entry_end) begin
                            dir_end_pending <= 1'b1;
                        end else if (cache_accept) begin
                            // 收满五项无需继续读取根目录其余扇区。
                            if (candidate_count == 3'd4)
                                dir_end_pending <= 1'b1;
                        end
                    end
                    pos <= pos + 1'b1;
                end
                if (sd_sec_read_end) begin
                    sd_sec_read<=0;state<=ST_DIR_END;
                end
            end
            ST_DIR_END:begin
                    // 最后一个目录项允许与 done 同拍，消费更新后的结束标志。
                    if (stop || dir_end_pending) begin
                        state<=ST_EMIT_CANDIDATE;
                    end else begin
                        advance_directory_sector;
                    end
            end
            ST_EMIT_CANDIDATE: if(!cache_write_busy)begin
                scan_done<=1'b1;
                if (candidate_count != 3'd0) begin
                    candidate_output_index<=0;
                    cache_read_word<=0;state<=ST_CACHE_PREFETCH;
                end else begin
                    candidate_valid<=1'b0;
                    state<=ST_HOLD;
                end
            end
            ST_WAIT_CANDIDATE: if (candidate_release) begin
                if (candidate_output_index + 1'b1 < candidate_count) begin
                    candidate_output_index<=candidate_output_index+1'b1;
                    // 先撤销 valid 一个时钟，再给出下一描述符。否则控制器会
                    // 在同一候选的旧描述符仍有效时再次启动加载。
                    candidate_valid<=1'b0;
                    state<=ST_NEXT_CANDIDATE;
                end else begin
                    candidate_valid<=1'b0;
                    state<=ST_HOLD;
                end
            end
            ST_NEXT_CANDIDATE: begin
                cache_read_word<=0;state<=ST_CACHE_PREFETCH;
            end
            ST_CACHE_PREFETCH:state<=ST_CACHE_READ;
            ST_CACHE_READ:begin
                case(cache_read_word)
                    2'd0:candidate_first_cluster[15:0]<=cache_read_data;
                    2'd1:candidate_first_cluster[31:16]<=cache_read_data;
                    2'd2:candidate_file_size[15:0]<=cache_read_data;
                    2'd3:candidate_file_size[31:16]<=cache_read_data;
                endcase
                if(cache_read_word==2'd3)begin candidate_valid<=1;state<=ST_WAIT_CANDIDATE;end
                else cache_read_word<=cache_read_word+2'd1;
            end
            ST_DIR_FAT: begin
                if (sd_sec_read_data_valid) begin
                    if (fat_entry_byte_valid)
                        fat_entry_shift<={sd_sec_read_data,fat_entry_shift[31:8]};
                    pos<=pos+1'b1;
                end
                if (sd_sec_read_end) begin
                    sd_sec_read<=0; pos<=0;
                    state<=ST_FAT_CAPTURE;
                end
            end
            ST_FAT_CAPTURE:begin
                fat_next_cluster_reg<=fat_entry_shift & 32'h0fff_ffff;
                state<=ST_DIR_FAT_CHECK;
            end
            ST_DIR_FAT_CHECK: begin
                    if (fat_next_cluster_reg>=32'h0fff_fff8 || fat_next_cluster_reg<32'd2) begin
                        state<=ST_EMIT_CANDIDATE;
                    end else begin
                        dir_cluster<=fat_next_cluster_reg; dir_sector_in_cluster<=0;
                        state<=ST_DIR_CALC;
                    end
            end
            ST_DIR_FAT_ADDR: begin
                sd_sec_read_addr<=fat_start_sector+dir_fat_sector_offset;
                sd_sec_read<=1'b1;
                pos<=0;
                state<=ST_DIR_FAT;
            end
            ST_HOLD: begin end
            default: state<=ST_IDLE;
        endcase
    end
end
endmodule
