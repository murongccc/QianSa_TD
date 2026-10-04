// BMP scanner and streaming 24-bit BI_RGB reader.
// Pixels are emitted in file order as RGB. Positive-height BMPs are therefore
// bottom-up; the SDRAM writer applies the corresponding vertical flip.
module bmp_read(
    input clk, input rst, output ready,
    input scan_start, input [31:0] scan_start_sector, input [31:0] scan_max_sector,
    input [2:0] scan_target_count, output reg scan_done,
    output reg scan_found_valid, output reg [31:0] scan_found_sector,
    output reg [2:0] scan_found_total,
    input load_start, input [31:0] load_sector, input sd_init_done,
    output reg [3:0] state_code, input [15:0] bmp_width, input [15:0] bmp_height,
    output reg [15:0] parsed_width, output reg [15:0] parsed_height,
    output reg parsed_top_down,
    output reg write_req, input write_req_ack,
    output reg sd_sec_read, output reg [31:0] sd_sec_read_addr,
    input [7:0] sd_sec_read_data, input sd_sec_read_data_valid, input sd_sec_read_end,
    output reg pixel_valid, input pixel_ready, output reg [23:0] pixel_data,
    output reg pixel_last, output reg frame_last,
    input sector_ready,
    output reg load_failed,
    // Legacy outputs are retained for source compatibility with old benches.
    output reg bmp_data_wr_en, output reg [23:0] bmp_data,
    input load_file_mode, input [31:0] load_first_cluster,
    input [31:0] load_file_size, input [31:0] fat_start_sector,
    input [31:0] first_data_sector, input [7:0] sectors_per_cluster
);

localparam ST_IDLE=4'd0, ST_SCAN=4'd1, ST_LOAD_HDR=4'd2, ST_LOAD_WAIT=4'd3,
           ST_LOAD_DATA=4'd4, ST_LOAD_PAD=4'd5, ST_LOAD_THROT=4'd6,
           ST_LOAD_FAT=4'd7, ST_LOAD_FAT_CLUSTER=4'd8,
           ST_LOAD_FAT_OFFSET=4'd9, ST_LOAD_FAT_ADDR=4'd10,
           ST_LOAD_FIRST_CLUSTER=4'd11, ST_LOAD_FIRST_OFFSET=4'd12,
           ST_LOAD_FIRST_ADDR=4'd13, ST_LOAD_FAT_CAPTURE=4'd14;
reg [3:0] state;
reg [9:0] rd_cnt;
reg [7:0] header_0, header_1;
reg [31:0] file_len, pixel_offset;
reg [15:0] width, height;
reg width_high_bad, height_high_zero, height_high_ones;
reg bit_count_ok, compression_bad;
reg top_down;
reg [31:0] scan_sector, load_sector_latched, bmp_len_cnt;
reg [1:0] bmp_byte_idx;
// 合法源图最大为 1920x1080，24 位像素的对齐行跨度不超过 5760 字节。
reg [12:0] row_byte_cnt, row_stride;
reg [31:0] output_pixel_count;
reg [7:0] b_byte, g_byte;
reg [10:0] src_col, src_row;
reg frame_seen;
reg header_valid;
reg file_mode_latched;
reg [31:0] file_cluster;
reg [7:0] file_sector_in_cluster;
reg [8:0] fat_offset;
reg [31:0] fat_entry;
reg [8:0] fat_byte_cnt;
reg [31:0] fat_next_cluster_reg, fat_cluster_offset, fat_data_sector_offset;
reg [31:0] file_size_latched, fat_start_sector_latched, first_data_sector_latched;
reg [7:0] sectors_per_cluster_latched;

wire [15:0] abs_height = top_down ? (~height + 16'd1) : height;
wire header_match = (header_0 == "B") && (header_1 == "M") &&
                    (file_len >= 32'd54) && (pixel_offset >= 32'd54) &&
                    (pixel_offset < file_len) && (width != 0) && (abs_height != 0) &&
                    !width_high_bad && (width <= 16'd1920) &&
                    (top_down ? height_high_ones : height_high_zero) && (abs_height <= 16'd1080) &&
                    bit_count_ok && !compression_bad;
wire [31:0] file_sector_count = (file_len == 0) ? 32'd1 : ((file_len + 511) >> 9);
wire [31:0] next_scan_sector_if_match = scan_sector + file_sector_count;
wire [31:0] next_scan_sector_if_miss = scan_sector + 1'b1;
wire bmp_data_valid = sd_sec_read_data_valid && (bmp_len_cnt >= pixel_offset) &&
                      (bmp_len_cnt < file_len);
// 只在完整 32 位图头校验通过后使用已锁存尺寸，避免截断非法图头。
wire [10:0] pixel_width = parsed_width[10:0];
wire [10:0] pixel_height = parsed_height[10:0];
wire [12:0] row_pixel_bytes = {2'b0,pixel_width} + {1'b0,pixel_width,1'b0};
wire [10:0] src_col_next = src_col + 11'd1;
wire [10:0] src_row_next = src_row + 11'd1;
wire source_row_last = (src_col_next >= pixel_width);
wire source_frame_last = source_row_last && (src_row_next >= pixel_height);
wire bmp_pixel_byte_valid = bmp_data_valid &&
                            (row_byte_cnt < row_pixel_bytes) &&
                            (!pixel_valid || pixel_ready);
assign ready = (state == ST_IDLE);

always @(posedge clk or posedge rst) begin
    if (rst) rd_cnt <= 0;
    else if ((state == ST_SCAN) || (state == ST_LOAD_HDR)) begin
        if (sd_sec_read_data_valid) rd_cnt <= rd_cnt + 1'b1;
        else if (sd_sec_read_end) rd_cnt <= 0;
    end else rd_cnt <= 0;
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        header_0<=0; header_1<=0; file_len<=0; pixel_offset<=54; width<=0;
        height<=0; compression_bad<=0; bit_count_ok<=0; top_down<=0; header_valid<=0;
        width_high_bad<=0;height_high_zero<=0;height_high_ones<=0;
    end else if (((state == ST_SCAN) || (state == ST_LOAD_HDR)) && sd_sec_read_data_valid) begin
        case (rd_cnt)
            0: begin header_0 <= sd_sec_read_data; header_valid <= 1'b0; end
            1: header_1 <= sd_sec_read_data;
            2: file_len[7:0] <= sd_sec_read_data;
            3: file_len[15:8] <= sd_sec_read_data;
            4: file_len[23:16] <= sd_sec_read_data;
            5: file_len[31:24] <= sd_sec_read_data;
            10: pixel_offset[7:0] <= sd_sec_read_data;
            11: pixel_offset[15:8] <= sd_sec_read_data;
            12: pixel_offset[23:16] <= sd_sec_read_data;
            13: pixel_offset[31:24] <= sd_sec_read_data;
            18: width[7:0] <= sd_sec_read_data;
            19: width[15:8] <= sd_sec_read_data;
            // 高位逐字节校验，不能把非法大尺寸截断成合法低位。
            20: width_high_bad <= sd_sec_read_data!=8'd0;
            21: width_high_bad <= width_high_bad || sd_sec_read_data!=8'd0;
            22: height[7:0] <= sd_sec_read_data;
            23: height[15:8] <= sd_sec_read_data;
            24: begin height_high_zero<=sd_sec_read_data==8'd0;height_high_ones<=sd_sec_read_data==8'hff;end
            25: begin
                height_high_zero<=height_high_zero && sd_sec_read_data==8'd0;
                height_high_ones<=height_high_ones && sd_sec_read_data==8'hff;
                top_down<=sd_sec_read_data[7];
            end
            28: bit_count_ok<=sd_sec_read_data==8'd24;
            29: bit_count_ok<=bit_count_ok && sd_sec_read_data==8'd0;
            30: compression_bad<=sd_sec_read_data!=8'd0;
            31,32,33: compression_bad<=compression_bad || sd_sec_read_data!=8'd0;
            // All fields used by header_match have settled one byte earlier.
            // Register the result so the large validation expression is not
            // part of the sector-address and state clock-enable paths.
            // FAT 目录长度可以大于 BMP 头 bfSize（例如文件尾有附加数据），
            // 只拒绝目录长度不足、会导致像素数据被截断的候选文件。
            34: header_valid <= header_match &&
                                (!file_mode_latched || (file_len <= file_size_latched));
            default: ;
        endcase
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state<=ST_IDLE; state_code<=0; sd_sec_read<=0; sd_sec_read_addr<=0;
        write_req<=0; scan_done<=0; scan_found_valid<=0; scan_found_sector<=0;
        scan_found_total<=0; scan_sector<=0; load_sector_latched<=0;
        bmp_len_cnt<=0; row_byte_cnt<=0; row_stride<=0; bmp_byte_idx<=0;
        output_pixel_count<=0; b_byte<=0; g_byte<=0; src_col<=0; src_row<=0;
        pixel_valid<=0; pixel_data<=0; pixel_last<=0; frame_last<=0;
        bmp_data_wr_en<=0; bmp_data<=0;
        parsed_width<=0; parsed_height<=0; parsed_top_down<=0;
        // frame_seen 在每次加载开始时清零，空闲/复位期间不参与输出。
        // 不连接异步复位，避免该内部标志引入复位 hold 修复布线。
        load_failed<=0;
        file_mode_latched<=0; file_cluster<=0; file_sector_in_cluster<=0;
        fat_offset<=0; fat_entry<=0; fat_byte_cnt<=0;
        fat_next_cluster_reg<=0; fat_cluster_offset<=0; fat_data_sector_offset<=0;
        file_size_latched<=0; fat_start_sector_latched<=0; first_data_sector_latched<=0;
        sectors_per_cluster_latched<=0;
    end else if (!sd_init_done) begin
        state<=ST_IDLE; state_code<=0; sd_sec_read<=0; write_req<=0;
        scan_done<=0; scan_found_valid<=0; scan_found_total<=0;
        pixel_valid<=0; pixel_last<=0; frame_last<=0; bmp_data_wr_en<=0;
    end else begin
        scan_found_valid<=0; pixel_last<=0; frame_last<=0; bmp_data_wr_en<=0;
        if (pixel_valid && pixel_ready) begin
            pixel_valid <= 1'b0;
            pixel_last <= 1'b0;
            frame_last <= 1'b0;
        end
        case (state)
            ST_IDLE: begin
                state_code<=1; sd_sec_read<=0; write_req<=0;
                if (scan_start) begin
                    scan_done<=0; scan_found_total<=0; scan_sector<=scan_start_sector;
                    sd_sec_read_addr<=scan_start_sector; state<=ST_SCAN;
                end else if (load_start) begin
                    file_mode_latched<=(load_file_mode === 1'b1);
                    file_cluster<=load_first_cluster;
                    file_sector_in_cluster<=0;
                    fat_byte_cnt<=0;
                    // 目录候选描述符跨模块而来，先全部锁存。不能将首簇
                    // 直接经过乘法/加法送往 SD 地址寄存器，否则会形成
                    // candidate_first_cluster -> sd_sec_read_addr 的长路径。
                    file_size_latched<=load_file_size;
                    fat_start_sector_latched<=fat_start_sector;
                    first_data_sector_latched<=first_data_sector;
                    sectors_per_cluster_latched<=sectors_per_cluster;
                    load_failed<=0; frame_seen<=0;
                    if (load_file_mode === 1'b1) begin
                        state<=ST_LOAD_FIRST_CLUSTER;
                    end else begin
                        load_sector_latched<=load_sector;
                        sd_sec_read_addr<=load_sector;
                        state<=ST_LOAD_HDR;
                    end
                end
            end
            ST_SCAN: begin
                state_code<=2; sd_sec_read<=1;
                if (sd_sec_read_end) begin
                    sd_sec_read<=0;
                    if (header_valid) begin
                        scan_found_valid<=1; scan_found_sector<=scan_sector;
                        scan_found_total<=scan_found_total+1'b1;
                        if ((scan_found_total+1'b1 >= scan_target_count) ||
                            (next_scan_sector_if_match > scan_max_sector)) begin
                            scan_done<=1; state<=ST_IDLE;
                        end else begin
                            scan_sector<=next_scan_sector_if_match;
                            sd_sec_read_addr<=next_scan_sector_if_match;
                        end
                    end else if (scan_sector >= scan_max_sector) begin
                        scan_done<=1; state<=ST_IDLE;
                    end else begin
                        scan_sector<=next_scan_sector_if_miss;
                        sd_sec_read_addr<=next_scan_sector_if_miss;
                    end
                end
            end
            ST_LOAD_HDR: begin
                state_code<=2; sd_sec_read<=1;
                if (sd_sec_read_end) begin
                    sd_sec_read<=0;
                    if (header_valid) begin
                        parsed_width<=width[15:0];
                        parsed_height<=abs_height[15:0];
                        parsed_top_down<=top_down;
                        write_req<=1; sd_sec_read_addr<=load_sector_latched; state<=ST_LOAD_WAIT;
                    end else begin load_failed<=1'b1; state<=ST_IDLE; end
                end
            end
            ST_LOAD_WAIT: begin
                state_code<=3;
                if (write_req_ack) begin
                    write_req<=0; state<=ST_LOAD_DATA; sd_sec_read<=1;
                    bmp_len_cnt<=0; row_byte_cnt<=0;
                    row_stride<=(row_pixel_bytes+13'd3)&13'h1ffc;
                    bmp_byte_idx<=0; output_pixel_count<=0; src_col<=0; src_row<=0;
                end
            end
            ST_LOAD_DATA: begin
                state_code<=4; sd_sec_read<=1;
                if (sd_sec_read_data_valid) begin
                    if (bmp_data_valid) begin
                        if (bmp_pixel_byte_valid) begin
                            case (bmp_byte_idx)
                                0: begin b_byte<=sd_sec_read_data; bmp_byte_idx<=1; end
                                1: begin g_byte<=sd_sec_read_data; bmp_byte_idx<=2; end
                                2: begin
                                    pixel_data<={sd_sec_read_data,g_byte,b_byte};
                                    bmp_data<= {sd_sec_read_data,g_byte,b_byte};
                                    pixel_last <= source_row_last;
                                    frame_last <= source_frame_last;
                                    if (source_frame_last)
                                        frame_seen <= 1'b1;
                                    pixel_valid <= 1'b1;
                                    bmp_data_wr_en <= 1'b1;
                                    bmp_byte_idx<=0;
                                    output_pixel_count<=output_pixel_count+1'b1;
                                    if (source_row_last) begin src_col<=0; src_row<=src_row_next; end
                                    else src_col<=src_col_next;
                                end
                                default: bmp_byte_idx<=0;
                            endcase
                        end
                        if (row_byte_cnt + 13'd1 >= row_stride) row_byte_cnt<=0;
                        else row_byte_cnt<=row_byte_cnt+13'd1;
                    end
                    bmp_len_cnt<=bmp_len_cnt+1'b1;
                end
                if (sd_sec_read_end) begin
                    sd_sec_read<=0;
                    if (bmp_len_cnt + 1'b1 >= file_len) begin
                        // A syntactically valid header is still invalid if
                        // the payload ends before a complete source frame.
                        if (!frame_seen && !(bmp_pixel_byte_valid &&
                            (bmp_byte_idx == 2) &&
                            source_frame_last))
                            load_failed<=1'b1;
                        state<=ST_IDLE;
                    end
                    else if (file_mode_latched) begin
                        if (file_sector_in_cluster + 1'b1 < sectors_per_cluster_latched) begin
                            file_sector_in_cluster<=file_sector_in_cluster+1'b1;
                            sd_sec_read_addr<=sd_sec_read_addr+1'b1;
                            state<=ST_LOAD_THROT;
                        end else begin
                            fat_offset<={file_cluster[6:0],2'b00};
                            sd_sec_read_addr<=fat_start_sector_latched+(file_cluster>>7);
                            fat_byte_cnt<=0;
                            state<=ST_LOAD_FAT;
                        end
                    end else begin sd_sec_read_addr<=sd_sec_read_addr+1'b1; state<=ST_LOAD_THROT; end
                end
            end
            ST_LOAD_THROT: begin
                state_code<=4'ha;
                // pixel_ready is driven from the source FIFO safety threshold.
                if (sector_ready && !pixel_valid) begin sd_sec_read<=1; state<=ST_LOAD_DATA; end
            end
            // 首簇地址计算与后续 FAT 跳簇使用同样的三级流水，保证目录器
            // 的候选寄存器不会直通 SD 地址，且不使用综合出的乘法器。
            ST_LOAD_FIRST_CLUSTER: begin
                state_code<=4'ha;
                if (file_cluster<32'd2) begin load_failed<=1'b1; state<=ST_IDLE; end
                else begin
                    fat_cluster_offset<=file_cluster-32'd2;
                    state<=ST_LOAD_FIRST_OFFSET;
                end
            end
            ST_LOAD_FIRST_OFFSET: begin
                state_code<=4'ha;
                case (sectors_per_cluster_latched)
                    8'd1:   fat_data_sector_offset<=fat_cluster_offset;
                    8'd2:   fat_data_sector_offset<=fat_cluster_offset<<1;
                    8'd4:   fat_data_sector_offset<=fat_cluster_offset<<2;
                    8'd8:   fat_data_sector_offset<=fat_cluster_offset<<3;
                    8'd16:  fat_data_sector_offset<=fat_cluster_offset<<4;
                    8'd32:  fat_data_sector_offset<=fat_cluster_offset<<5;
                    8'd64:  fat_data_sector_offset<=fat_cluster_offset<<6;
                    8'd128: fat_data_sector_offset<=fat_cluster_offset<<7;
                    default: begin load_failed<=1'b1; fat_data_sector_offset<=0; end
                endcase
                state<=ST_LOAD_FIRST_ADDR;
            end
            ST_LOAD_FIRST_ADDR: begin
                state_code<=4'ha;
                if (sectors_per_cluster_latched==0 ||
                    (sectors_per_cluster_latched & (sectors_per_cluster_latched-1'b1)) != 0) begin
                    load_failed<=1'b1; state<=ST_IDLE;
                end else begin
                    load_sector_latched<=first_data_sector_latched+fat_data_sector_offset;
                    sd_sec_read_addr<=first_data_sector_latched+fat_data_sector_offset;
                    state<=ST_LOAD_HDR;
                end
            end
            ST_LOAD_FAT: begin
                state_code<=4'ha; sd_sec_read<=1;
                if (sd_sec_read_data_valid) begin
                    if (fat_byte_cnt[8:2]==fat_offset[8:2])
                        fat_entry<={sd_sec_read_data,fat_entry[31:8]};
                    fat_byte_cnt<=fat_byte_cnt+1'b1;
                end
                if (sd_sec_read_end) begin
                    sd_sec_read<=0; fat_byte_cnt<=0;
                    // FAT 的四个字节先完整锁存，随后分三拍计算下一簇的
                    // 数据区地址。避免 FAT 数据寄存器直通可变乘法到 SD 地址。
                    state<=ST_LOAD_FAT_CAPTURE;
                end
            end
            // 结束脉冲允许与最后字节同拍；下一拍才使用完整四字节。
            ST_LOAD_FAT_CAPTURE: begin
                fat_next_cluster_reg<=fat_entry & 32'h0fff_ffff;
                state<=ST_LOAD_FAT_CLUSTER;
            end
            ST_LOAD_FAT_CLUSTER: begin
                state_code<=4'ha;
                if (fat_next_cluster_reg>=32'h0fff_fff8 || fat_next_cluster_reg<32'd2) begin
                    load_failed<=1'b1; state<=ST_IDLE;
                end else begin
                    file_cluster<=fat_next_cluster_reg;
                    file_sector_in_cluster<=0;
                    fat_cluster_offset<=fat_next_cluster_reg-32'd2;
                    state<=ST_LOAD_FAT_OFFSET;
                end
            end
            ST_LOAD_FAT_OFFSET: begin
                state_code<=4'ha;
                // FAT32 的每簇扇区数是 1、2、4…128；使用固定移位替代乘法。
                case (sectors_per_cluster_latched)
                    8'd1:   fat_data_sector_offset<=fat_cluster_offset;
                    8'd2:   fat_data_sector_offset<=fat_cluster_offset<<1;
                    8'd4:   fat_data_sector_offset<=fat_cluster_offset<<2;
                    8'd8:   fat_data_sector_offset<=fat_cluster_offset<<3;
                    8'd16:  fat_data_sector_offset<=fat_cluster_offset<<4;
                    8'd32:  fat_data_sector_offset<=fat_cluster_offset<<5;
                    8'd64:  fat_data_sector_offset<=fat_cluster_offset<<6;
                    8'd128: fat_data_sector_offset<=fat_cluster_offset<<7;
                    default: begin load_failed<=1'b1; fat_data_sector_offset<=0; end
                endcase
                state<=ST_LOAD_FAT_ADDR;
            end
            ST_LOAD_FAT_ADDR: begin
                state_code<=4'ha;
                if (sectors_per_cluster_latched==0 ||
                    (sectors_per_cluster_latched & (sectors_per_cluster_latched-1'b1)) != 0) begin
                    load_failed<=1'b1; state<=ST_IDLE;
                end else begin
                    sd_sec_read_addr<=first_data_sector_latched+fat_data_sector_offset;
                    state<=ST_LOAD_THROT;
                end
            end
            default: state<=ST_IDLE;
        endcase
    end
end
endmodule
