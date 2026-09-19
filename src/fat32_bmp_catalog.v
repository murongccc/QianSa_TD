// FAT32 根目录 BMP 候选器。
// 目录项按物理出现顺序输出；一个候选完成加载或失败后才继续枚举，
// 因此不需要缓存整张目录，也能在坏文件后补足可用图片。
module fat32_bmp_catalog(
    input wire clk, input wire rst, input wire sd_init_done,
    output reg sd_sec_read, output reg [31:0] sd_sec_read_addr,
    input wire sd_sec_read_data_valid, input wire [7:0] sd_sec_read_data,
    input wire sd_sec_read_end,
    output reg candidate_valid, output reg [31:0] candidate_first_cluster,
    output reg [31:0] candidate_file_size,
    output reg [31:0] fat_start_sector, output reg [31:0] first_data_sector,
    output reg [7:0] sectors_per_cluster,
    input wire candidate_release, input wire stop,
    output reg scan_done, output reg volume_valid
);
localparam ST_IDLE=4'd0, ST_MBR=4'd1, ST_BPB=4'd2, ST_SETUP=4'd3,
           ST_DIR_CALC=4'd4, ST_DIR=4'd5, ST_DIR_FAT=4'd6,
           ST_WAIT_CANDIDATE=4'd7, ST_HOLD=4'd8,
           ST_DIR_OFFSET=4'd9, ST_DIR_ADDR=4'd10,
           ST_DIR_FAT_CHECK=4'd11, ST_DIR_FAT_ADDR=4'd12;
reg [3:0] state;
reg [9:0] pos;
reg [7:0] ent [0:31];
integer i;
reg [15:0] bytes_per_sector, reserved_sector_count;
reg [7:0] fat_count;
reg [31:0] sectors_per_fat, root_cluster, volume_base;
reg [31:0] mbr_partition_lba;
reg mbr_entry_is_fat, mbr_found_partition, mbr_writing_lba;
reg [31:0] dir_cluster, dir_sector;
reg [31:0] dir_cluster_offset, dir_data_sector_offset, dir_fat_sector_offset;
reg [7:0] dir_sector_in_cluster;
reg [9:0] resume_offset;
reg candidate_pending;
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
        resume_offset <= 10'd0;
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
        scan_done<=0; volume_valid<=0; bytes_per_sector<=0; reserved_sector_count<=0;
        fat_count<=0; sectors_per_fat<=0; root_cluster<=0; volume_base<=0;
        mbr_partition_lba<=0; mbr_entry_is_fat<=0; mbr_found_partition<=0; mbr_writing_lba<=0;
        dir_cluster<=0; dir_sector<=0; dir_cluster_offset<=0;
        dir_data_sector_offset<=0; dir_fat_sector_offset<=0;
        dir_sector_in_cluster<=0; resume_offset<=0; candidate_pending<=0;
        fat_offset<=0; fat_b0<=0; fat_b1<=0; fat_b2<=0; fat_b3<=0;
        fat_next_cluster_reg<=0;
        for (i=0;i<32;i=i+1) ent[i]<=0;
    end else begin
        case (state)
            ST_IDLE: if (sd_init_done) begin
                scan_done<=0; volume_valid<=0; candidate_valid<=0; candidate_pending<=0;
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
                    if (bpb_looks_valid) begin
                        volume_base<=0; state<=ST_SETUP;
                    end else if (mbr_found_partition) begin
                        volume_base<=mbr_partition_lba; sd_sec_read_addr<=mbr_partition_lba;
                        sd_sec_read<=1'b1; state<=ST_BPB;
                    end else begin
                        scan_done<=1'b1; state<=ST_HOLD;
                    end
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
                    if (bpb_looks_valid) state<=ST_SETUP;
                    else begin scan_done<=1'b1; state<=ST_HOLD; end
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
                    if (pos >= resume_offset) begin
                        ent[pos[4:0]] <= sd_sec_read_data;
                        if ((pos[4:0] == 5'd31) && !candidate_pending) begin
                            if (ent[0] == 8'h00) begin
                                scan_done <= 1'b1;
                            end else if (dir_entry_is_bmp) begin
                                candidate_first_cluster <= {ent[21],ent[20],ent[27],ent[26]};
                                candidate_file_size <= {sd_sec_read_data,ent[30],ent[29],ent[28]};
                                candidate_pending <= 1'b1;
                                resume_offset <= pos + 1'b1;
                            end
                        end
                    end
                    pos <= pos + 1'b1;
                end
                if (sd_sec_read_end) begin
                    sd_sec_read<=0;
                    // 若候选项正好是本扇区最后一个目录项，candidate_pending
                    // 仍在本拍写入；同时检查本拍命中条件，避免漏掉该文件。
                    if (stop || scan_done) begin scan_done<=1'b1; state<=ST_HOLD; end
                    else if (candidate_pending ||
                        (sd_sec_read_data_valid && (pos[4:0]==5'd31) &&
                         !candidate_pending && dir_entry_is_bmp)) begin
                        candidate_valid<=1'b1; candidate_pending<=0; state<=ST_WAIT_CANDIDATE;
                    end else begin
                        advance_directory_sector;
                    end
                end
            end
            ST_WAIT_CANDIDATE: if (stop || candidate_release) begin
                candidate_valid<=0;
                if (stop) begin scan_done<=1'b1; state<=ST_HOLD; end
                else if (resume_offset >= 10'd512) begin
                    advance_directory_sector;
                end else begin
                    pos<=0; sd_sec_read_addr<=dir_sector; sd_sec_read<=1'b1; state<=ST_DIR;
                end
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
                        scan_done<=1'b1; state<=ST_HOLD;
                    end else begin
                        dir_cluster<=fat_next_cluster_reg; dir_sector_in_cluster<=0;
                        resume_offset<=0; state<=ST_DIR_CALC;
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
