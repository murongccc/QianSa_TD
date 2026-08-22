// Independent SD media pipeline: a catalogue records discovered BMP files,
// while media_session_controller owns the playback policy and frame-slot state.
module sd_media_pipeline #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter [31:0] SCAN_START_SECTOR = 32'd0,
    parameter [31:0] SCAN_MAX_SECTOR = 32'd131071,
    parameter [2:0] SCAN_TARGET_COUNT = 3'd4
)(
    input wire clk, input wire rst, input wire key_next, input wire key_auto,
    input wire [2:0] uart_command_async, input wire uart_command_toggle_async,
    output wire [3:0] state_code, input wire [15:0] bmp_width, input wire [15:0] bmp_height,
    output wire display_valid, input wire write_finish_toggle,
    output wire auto_play_enabled,
    output wire [1:0] write_buf_idx, output wire [1:0] disp_buf_idx,
    output wire write_req, input wire write_req_ack, output wire write_en,
    output wire [31:0] write_data, output wire SD_nCS, output wire SD_DCLK,
    output wire SD_MOSI, input wire SD_MISO
);
wire sd_sec_read; wire [31:0] sd_sec_read_addr; wire [7:0] sd_sec_read_data;
wire sd_sec_read_data_valid, sd_sec_read_end, bmp_data_wr_en, sd_init_done, bmp_ready;
wire scan_done, scan_found_valid; wire [31:0] scan_found_sector; wire [2:0] scan_found_total;
reg scan_start, scan_kicked, source_complete;
reg [2:0] media_count; reg [31:0] media_sector0, media_sector1, media_sector2, media_sector3;
reg [2:0] write_finish_sync;
wire load_start, load_inflight; wire [1:0] load_media_index;
wire write_complete = write_finish_sync[2] ^ write_finish_sync[1];
wire frame_commit = load_inflight && source_complete && write_complete;
wire [23:0] bmp_data;

function [31:0] selected_sector;
    input [1:0] index;
    begin
        case(index)
            2'd0: selected_sector=media_sector0;
            2'd1: selected_sector=media_sector1;
            2'd2: selected_sector=media_sector2;
            default: selected_sector=media_sector3;
        endcase
    end
endfunction

assign write_en= bmp_data_wr_en;
assign write_data = {bmp_data,8'd0};

always @(posedge clk or posedge rst) begin
    if (rst) begin
        scan_start<=1'b0; scan_kicked<=1'b0; source_complete<=1'b0; write_finish_sync<=3'd0;
        media_count<=3'd0; media_sector0<=32'd0; media_sector1<=32'd0; media_sector2<=32'd0; media_sector3<=32'd0;
    end else begin
        scan_start<=1'b0;
        write_finish_sync<={write_finish_sync[1:0],write_finish_toggle};
        if (!sd_init_done) begin scan_kicked<=1'b0; media_count<=3'd0; source_complete<=1'b0; end
        else begin
            if (!scan_kicked && bmp_ready) begin scan_start<=1'b1; scan_kicked<=1'b1; media_count<=3'd0; end
            if (scan_found_valid && media_count<SCAN_TARGET_COUNT) begin
                case(media_count)
                    3'd0: media_sector0<=scan_found_sector;
                    3'd1: media_sector1<=scan_found_sector;
                    3'd2: media_sector2<=scan_found_sector;
                    default: media_sector3<=scan_found_sector;
                endcase
                media_count<=media_count+3'd1;
            end
            if (!load_inflight) source_complete<=1'b0;
            else if (bmp_ready) source_complete<=1'b1;
        end
    end
end

media_session_controller #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.AUTO_PERIOD_SECONDS(3)) u_session (
    .clk(clk),.rst(rst),.key_next(key_next),.key_auto(key_auto),.scan_done(scan_done),
    .uart_command_async(uart_command_async),.uart_command_toggle_async(uart_command_toggle_async),
    .media_count(media_count),.loader_ready(bmp_ready),.frame_commit(frame_commit),.load_start(load_start),
    .load_media_index(load_media_index),.write_slot(write_buf_idx),.display_slot(disp_buf_idx),
    .display_valid(display_valid),.auto_play_enabled(auto_play_enabled),.load_inflight(load_inflight)
);

bmp_read u_bmp_read(
    .clk(clk),.rst(rst),.ready(bmp_ready),.scan_start(scan_start),.scan_start_sector(SCAN_START_SECTOR),
    .scan_max_sector(SCAN_MAX_SECTOR),.scan_target_count(SCAN_TARGET_COUNT),.scan_done(scan_done),
    .scan_found_valid(scan_found_valid),.scan_found_sector(scan_found_sector),.scan_found_total(scan_found_total),
    .load_start(load_start),.load_sector(selected_sector(load_media_index)),.sd_init_done(sd_init_done),
    .state_code(state_code),.bmp_width(bmp_width),.bmp_height(bmp_height),.write_req(write_req),
    .write_req_ack(write_req_ack),.sd_sec_read(sd_sec_read),.sd_sec_read_addr(sd_sec_read_addr),
    .sd_sec_read_data(sd_sec_read_data),.sd_sec_read_data_valid(sd_sec_read_data_valid),
    .sd_sec_read_end(sd_sec_read_end),.bmp_data_wr_en(bmp_data_wr_en),.bmp_data(bmp_data)
);

sd_card_top u_sd(
    .clk(clk),.rst(rst),.SD_nCS(SD_nCS),.SD_DCLK(SD_DCLK),.SD_MOSI(SD_MOSI),.SD_MISO(SD_MISO),
    .sd_init_done(sd_init_done),.sd_sec_read(sd_sec_read),.sd_sec_read_addr(sd_sec_read_addr),
    .sd_sec_read_data(sd_sec_read_data),.sd_sec_read_data_valid(sd_sec_read_data_valid),.sd_sec_read_end(sd_sec_read_end),
    .sd_sec_write(1'b0),.sd_sec_write_addr(32'd0),.sd_sec_write_data(),.sd_sec_write_data_req(),.sd_sec_write_end()
);
endmodule
