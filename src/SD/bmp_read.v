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
    output reg bmp_data_wr_en, output reg [23:0] bmp_data
);

localparam ST_IDLE=3'd0, ST_SCAN=3'd1, ST_LOAD_HDR=3'd2, ST_LOAD_WAIT=3'd3,
           ST_LOAD_DATA=3'd4, ST_LOAD_PAD=3'd5, ST_LOAD_THROT=3'd6;
reg [2:0] state;
reg [9:0] rd_cnt;
reg [7:0] header_0, header_1;
reg [31:0] file_len, pixel_offset, width, height, compression;
reg [15:0] bit_count;
reg top_down;
reg [31:0] scan_sector, load_sector_latched, bmp_len_cnt;
reg [1:0] bmp_byte_idx;
reg [31:0] row_byte_cnt, row_stride;
reg [31:0] output_pixel_count;
reg [7:0] b_byte, g_byte;
reg [15:0] src_col, src_row;
reg frame_seen;
reg header_valid;

wire [31:0] abs_height = height[31] ? (~height + 32'd1) : height;
wire header_match = (header_0 == "B") && (header_1 == "M") &&
                    (file_len >= 32'd54) && (pixel_offset >= 32'd54) &&
                    (pixel_offset < file_len) && (width != 0) && (height != 0) &&
                    (width <= 32'd1920) &&
                    (((height[31] == 1'b0) && (height <= 32'd1080)) ||
                     ((height[31] == 1'b1) && ((~height + 1'b1) <= 32'd1080))) &&
                    (bit_count == 16'd24) && (compression == 0);
wire [31:0] file_sector_count = (file_len == 0) ? 32'd1 : ((file_len + 511) >> 9);
wire [31:0] next_scan_sector_if_match = scan_sector + file_sector_count;
wire [31:0] next_scan_sector_if_miss = scan_sector + 1'b1;
wire bmp_data_valid = sd_sec_read_data_valid && (bmp_len_cnt >= pixel_offset) &&
                      (bmp_len_cnt < file_len);
wire bmp_pixel_byte_valid = bmp_data_valid &&
                            (row_byte_cnt < (width + (width << 1))) &&
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
        height<=0; compression<=0; bit_count<=0; top_down<=0; header_valid<=0;
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
            20: width[23:16] <= sd_sec_read_data;
            21: width[31:24] <= sd_sec_read_data;
            22: height[7:0] <= sd_sec_read_data;
            23: height[15:8] <= sd_sec_read_data;
            24: height[23:16] <= sd_sec_read_data;
            25: begin height[31:24] <= sd_sec_read_data; top_down <= sd_sec_read_data[7]; end
            28: bit_count[7:0] <= sd_sec_read_data;
            29: bit_count[15:8] <= sd_sec_read_data;
            30: compression[7:0] <= sd_sec_read_data;
            31: compression[15:8] <= sd_sec_read_data;
            32: compression[23:16] <= sd_sec_read_data;
            33: compression[31:24] <= sd_sec_read_data;
            // All fields used by header_match have settled one byte earlier.
            // Register the result so the large validation expression is not
            // part of the sector-address and state clock-enable paths.
            34: header_valid <= header_match;
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
        load_failed<=0; frame_seen<=0;
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
                    load_sector_latched<=load_sector; sd_sec_read_addr<=load_sector;
                    load_failed<=0; frame_seen<=0;
                    state<=ST_LOAD_HDR;
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
                    row_stride<=(width+(width<<1)+3)&32'hffff_fffc;
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
                                    pixel_last <= (src_col + 1'b1 >= width[15:0]);
                                    frame_last <= (src_col + 1'b1 >= width[15:0]) &&
                                                  (src_row + 1'b1 >= abs_height[15:0]);
                                    if ((src_col + 1'b1 >= width[15:0]) &&
                                        (src_row + 1'b1 >= abs_height[15:0]))
                                        frame_seen <= 1'b1;
                                    pixel_valid <= 1'b1;
                                    bmp_data_wr_en <= 1'b1;
                                    bmp_byte_idx<=0;
                                    output_pixel_count<=output_pixel_count+1'b1;
                                    if (src_col + 1'b1 >= width[15:0]) begin src_col<=0; src_row<=src_row+1'b1; end
                                    else src_col<=src_col+1'b1;
                                end
                                default: bmp_byte_idx<=0;
                            endcase
                        end
                        if (row_byte_cnt + 1'b1 >= row_stride) row_byte_cnt<=0;
                        else row_byte_cnt<=row_byte_cnt+1'b1;
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
                            (src_col + 1'b1 >= width[15:0]) &&
                            (src_row + 1'b1 >= abs_height[15:0])))
                            load_failed<=1'b1;
                        state<=ST_IDLE;
                    end
                    else begin sd_sec_read_addr<=sd_sec_read_addr+1'b1; state<=ST_LOAD_THROT; end
                end
            end
            ST_LOAD_THROT: begin
                state_code<=4'ha;
                // pixel_ready is driven from the source FIFO safety threshold.
                if (sector_ready && !pixel_valid) begin sd_sec_read<=1; state<=ST_LOAD_DATA; end
            end
            default: state<=ST_IDLE;
        endcase
    end
end
endmodule
