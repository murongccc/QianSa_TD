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
    output reg scan_done, output reg volume_valid
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
reg [3:0] state;
reg [9:0] pos;
reg [7:0] ent [0:31];
integer i;
reg [15:0] bytes_per_sector, reserved_sector_count;
reg [7:0] fat_count;
reg [31:0] sectors_per_fat, root_cluster, volume_base;
reg [31:0] mbr_partition_lba;
reg mbr_entry_is_fat, mbr_found_partition, mbr_writing_lba;
// 0：刚读完 LBA0，可在 BPB 无效时回退到 MBR 分区；
// 1：刚读完 MBR 指向的 BPB，校验失败即结束扫描。
reg validate_from_mbr;
reg [31:0] dir_cluster, dir_sector;
reg [31:0] dir_cluster_offset, dir_data_sector_offset, dir_fat_sector_offset;
reg [7:0] dir_sector_in_cluster;
reg [2:0] candidate_output_index;
reg dir_end_pending;
reg [31:0] cached_first_cluster [0:4];
reg [31:0] cached_file_size [0:4];
reg [8:0] fat_offset;
reg [7:0] fat_b0, fat_b1, fat_b2, fat_b3;
reg [31:0] fat_next_cluster_reg;

wire bpb_looks_valid = (bytes_per_sector == 16'd512) &&
                       (sectors_per_cluster != 8'd0) &&
                       (fat_count != 8'd0) && (sectors_per_fat != 32'd0) &&
                       (root_cluster >= 32'd2);
wire dir_entry_is_bmp = (ent[0] != 8'h00) && (ent[0] != 8'he5) &&
                        (ent[11] != 8'h0f) && (ent[11] != 8'h10) &&
                        (ent[11] != 8'h08) &&
                        (ent[8] == "B") && (ent[9] == "M") && (ent[10] == "P") &&
                        ({ent[21],ent[20],ent[27],ent[26]} >= 32'd2) &&
                        ({sd_sec_read_data,ent[30],ent[29],ent[28]} != 32'd0);

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
        scan_done<=0; volume_valid<=0; bytes_per_sector<=0; reserved_sector_count<=0;
        fat_count<=0; sectors_per_fat<=0; root_cluster<=0; volume_base<=0;
        mbr_partition_lba<=0; mbr_entry_is_fat<=0; mbr_found_partition<=0; mbr_writing_lba<=0;
        validate_from_mbr<=1'b0;
        dir_cluster<=0; dir_sector<=0; dir_cluster_offset<=0;
        dir_data_sector_offset<=0; dir_fat_sector_offset<=0;
        dir_sector_in_cluster<=0; candidate_output_index<=0; dir_end_pending<=0;
        fat_offset<=0; fat_b0<=0; fat_b1<=0; fat_b2<=0; fat_b3<=0;
        fat_next_cluster_reg<=0;
        for (i=0;i<32;i=i+1) begin
            ent[i]<=0;
            if (i<5) begin
                cached_first_cluster[i]<=0;
                cached_file_size[i]<=0;
            end
        end
    end else begin
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
                    if (pos==10'd11) bytes_per_sector[7:0]<=sd_sec_read_data;
                    if (pos==10'd12) bytes_per_sector[15:8]<=sd_sec_read_data;
                    if (pos==10'd13) sectors_per_cluster<=sd_sec_read_data;
                    if (pos==10'd14) reserved_sector_count[7:0]<=sd_sec_read_data;
                    if (pos==10'd15) reserved_sector_count[15:8]<=sd_sec_read_data;
                    if (pos==10'd16) fat_count<=sd_sec_read_data;
                    if (pos>=10'd36 && pos<=10'd39) sectors_per_fat[(pos-10'd36)*8 +: 8]<=sd_sec_read_data;
                    if (pos>=10'd44 && pos<=10'd47) root_cluster[(pos-10'd44)*8 +: 8]<=sd_sec_read_data;
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
                    if (pos==10'd11) bytes_per_sector[7:0]<=sd_sec_read_data;
                    if (pos==10'd12) bytes_per_sector[15:8]<=sd_sec_read_data;
                    if (pos==10'd13) sectors_per_cluster<=sd_sec_read_data;
                    if (pos==10'd14) reserved_sector_count[7:0]<=sd_sec_read_data;
                    if (pos==10'd15) reserved_sector_count[15:8]<=sd_sec_read_data;
                    if (pos==10'd16) fat_count<=sd_sec_read_data;
                    if (pos>=10'd36 && pos<=10'd39) sectors_per_fat[(pos-10'd36)*8 +: 8]<=sd_sec_read_data;
                    if (pos>=10'd44 && pos<=10'd47) root_cluster[(pos-10'd44)*8 +: 8]<=sd_sec_read_data;
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
                    dir_cluster_offset<=dir_cluster-32'd2;
                    state<=ST_DIR_OFFSET;
                end
            end
            ST_DIR_OFFSET: begin
                // FAT32 每簇扇区数只能是 1、2、4…128，用固定移位代替乘法。
                case (sectors_per_cluster)
                    8'd1:   begin dir_data_sector_offset<=dir_cluster_offset;    state<=ST_DIR_ADDR; end
                    8'd2:   begin dir_data_sector_offset<=dir_cluster_offset<<1; state<=ST_DIR_ADDR; end
                    8'd4:   begin dir_data_sector_offset<=dir_cluster_offset<<2; state<=ST_DIR_ADDR; end
                    8'd8:   begin dir_data_sector_offset<=dir_cluster_offset<<3; state<=ST_DIR_ADDR; end
                    8'd16:  begin dir_data_sector_offset<=dir_cluster_offset<<4; state<=ST_DIR_ADDR; end
                    8'd32:  begin dir_data_sector_offset<=dir_cluster_offset<<5; state<=ST_DIR_ADDR; end
                    8'd64:  begin dir_data_sector_offset<=dir_cluster_offset<<6; state<=ST_DIR_ADDR; end
                    8'd128: begin dir_data_sector_offset<=dir_cluster_offset<<7; state<=ST_DIR_ADDR; end
                    default: begin scan_done<=1'b1; state<=ST_HOLD; end
                endcase
            end
            ST_DIR_ADDR: begin
                dir_sector<=first_data_sector+dir_data_sector_offset;
                sd_sec_read_addr<=first_data_sector+dir_data_sector_offset;
                sd_sec_read<=1'b1;
                pos<=0;
                state<=ST_DIR;
            end
            ST_DIR: begin
                if (sd_sec_read_data_valid) begin
                    ent[pos[4:0]] <= sd_sec_read_data;
                    if (pos[4:0] == 5'd31) begin
                        if (ent[0] == 8'h00) begin
                            dir_end_pending <= 1'b1;
                        end else if (dir_entry_is_bmp && candidate_count < 3'd5) begin
                            cached_first_cluster[candidate_count] <= {ent[21],ent[20],ent[27],ent[26]};
                            cached_file_size[candidate_count] <= {sd_sec_read_data,ent[30],ent[29],ent[28]};
                            candidate_count <= candidate_count+1'b1;
                            // 收满五项无需继续读取根目录其余扇区。
                            if (candidate_count == 3'd4)
                                dir_end_pending <= 1'b1;
                        end
                    end
                    pos <= pos + 1'b1;
                end
                if (sd_sec_read_end) begin
                    sd_sec_read<=0;
                    if (stop || dir_end_pending) begin
                        state<=ST_EMIT_CANDIDATE;
                    end else begin
                        advance_directory_sector;
                    end
                end
            end
            ST_EMIT_CANDIDATE: begin
                scan_done<=1'b1;
                if (candidate_count != 3'd0) begin
                    candidate_output_index<=0;
                    candidate_first_cluster<=cached_first_cluster[0];
                    candidate_file_size<=cached_file_size[0];
                    candidate_valid<=1'b1;
                    state<=ST_WAIT_CANDIDATE;
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
                candidate_first_cluster<=cached_first_cluster[candidate_output_index];
                candidate_file_size<=cached_file_size[candidate_output_index];
                candidate_valid<=1'b1;
                state<=ST_WAIT_CANDIDATE;
            end
            ST_DIR_FAT: begin
                if (sd_sec_read_data_valid) begin
                    if (pos==fat_offset) fat_b0<=sd_sec_read_data;
                    if (pos==fat_offset+1'b1) fat_b1<=sd_sec_read_data;
                    if (pos==fat_offset+2'd2) fat_b2<=sd_sec_read_data;
                    if (pos==fat_offset+2'd3) fat_b3<=sd_sec_read_data;
                    pos<=pos+1'b1;
                end
                if (sd_sec_read_end) begin
                    sd_sec_read<=0; pos<=0;
                    fat_next_cluster_reg<={fat_b3,fat_b2,fat_b1,fat_b0} & 32'h0fff_ffff;
                    state<=ST_DIR_FAT_CHECK;
                end
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
