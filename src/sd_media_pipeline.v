// Independent SD media pipeline: a catalogue records discovered BMP files,
// while media_session_controller owns the playback policy and frame-slot state.
module sd_media_pipeline #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter [31:0] SCAN_START_SECTOR = 32'd0,
    parameter [31:0] SCAN_MAX_SECTOR = 32'd131071,
    parameter [2:0] SCAN_TARGET_COUNT = 3'd3
)(
    input wire clk, input wire rst, input wire key_next, input wire key_auto,
    input wire [2:0] uart_command_async, input wire uart_command_toggle_async,
    output wire [3:0] state_code, input wire [15:0] bmp_width, input wire [15:0] bmp_height,
    output wire display_valid, input wire write_finish_toggle,
    output wire auto_play_enabled,
    output wire [1:0] write_buf_idx, output wire [1:0] disp_buf_idx,
    output wire write_req, input wire write_req_ack, output wire write_en,
    output wire [31:0] write_data, output wire SD_nCS, output wire SD_DCLK,
    output wire SD_MOSI, input wire SD_MISO,
    output wire audio_fifo_we, output wire [31:0] audio_fifo_din,
    input wire audio_fifo_full, input wire audio_read_toggle,
    output wire audio_reader_busy, output wire audio_reader_done
);
wire sd_sec_read; wire [31:0] sd_sec_read_addr; wire [7:0] sd_sec_read_data;
wire sd_sec_read_data_valid, sd_sec_read_end, bmp_data_wr_en, sd_init_done, bmp_ready;
wire [3:0] bmp_state_code;
wire audio_sd_read; wire [31:0] audio_sd_addr;
wire audio_busy, audio_done, audio_file_found, audio_format_ok, audio_format_error;
wire [31:0] audio_fifo_din_int;
wire sd_read_mux; wire [31:0] sd_addr_mux;
wire [7:0] sd_data_bmp = sd_sec_read_data;
wire [7:0] sd_data_audio = sd_sec_read_data;
wire sd_valid_bmp, sd_end_bmp, sd_valid_audio, sd_end_audio;
wire scan_done, scan_found_valid; wire [31:0] scan_found_sector; wire [2:0] scan_found_total;
reg scan_start, scan_kicked, source_complete, load_started;
reg [2:0] media_count; reg [31:0] media_sector0, media_sector1, media_sector2, media_sector3;
reg [2:0] write_finish_sync;
reg write_toggle_baseline;
reg write_complete_pending;
reg sd_init_seen;
wire sd_init_qualified = sd_init_done | sd_init_seen;
wire load_start, load_inflight; wire [1:0] load_media_index;
wire write_complete = load_inflight && (write_finish_sync[2] != write_toggle_baseline);
// The SD source and SDRAM writer finish in unrelated clock domains.  The old
// one-cycle write_complete pulse had to coincide with source_complete; if it
// arrived first, frame_commit was missed permanently and load_inflight never
// cleared, which disabled both keys and automatic playback.  Keep the write
// completion pending until the current BMP source has also returned to ready.
wire frame_commit = load_inflight && source_complete && write_complete_pending;
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
assign audio_fifo_din = audio_fifo_din_int;
assign audio_reader_busy = audio_busy;
assign audio_reader_done = audio_done;
// 8 explicitly reports a completed search with no BMP. The old UI silently
// fell back to idle (1). 9 reports WAV lookup completed without a match.
reg audio_not_found;
reg audio_bad_format;
reg audio_ok_seen;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        audio_not_found<=0; audio_bad_format<=0; audio_ok_seen<=0;
    end else if (audio_done && !audio_file_found) begin
        audio_not_found<=1;
    end else if (audio_format_error) begin
        audio_bad_format<=1;
    end else if (audio_format_ok) begin
        // Keep a successful format result visible after the reader leaves its
        // metadata/search state; otherwise the display falls back to BMP
        // idle (1) while audio may already be streaming.
        audio_ok_seen<=1;
    end
end
assign state_code = !sd_init_qualified ? 4'd0 :
                    (scan_done && media_count==0) ? 4'd8 :
                    (load_inflight && source_complete && !write_complete_pending) ? 4'd3 :
                    audio_not_found ? 4'd9 :
                    audio_bad_format ? 4'd7 :
                    audio_ok_seen ? 4'd6 :
                    (display_valid && audio_busy) ?
                    (audio_format_ok ? 4'd6 : (audio_file_found ? 4'd7 : 4'd5)) : bmp_state_code;

sd_sector_arbiter u_sd_arbiter (
    .clk(clk), .rst(rst), .bmp_req(sd_sec_read), .bmp_addr(sd_sec_read_addr),
    .audio_req(audio_sd_read), .audio_addr(audio_sd_addr),
    .sd_req(sd_read_mux), .sd_addr(sd_addr_mux),
    .sd_valid(sd_sec_read_data_valid), .sd_done(sd_sec_read_end),
    .bmp_valid(sd_valid_bmp), .bmp_done(sd_end_bmp),
    .audio_valid(sd_valid_audio), .audio_done(sd_end_audio)
);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        scan_start<=1'b0; scan_kicked<=1'b0; source_complete<=1'b0; load_started<=1'b0;
        write_finish_sync<=3'd0; write_toggle_baseline<=1'b0; write_complete_pending<=1'b0;
        sd_init_seen<=1'b0;
        media_count<=3'd0; media_sector0<=32'd0; media_sector1<=32'd0; media_sector2<=32'd0; media_sector3<=32'd0;
    end else begin
        scan_start<=1'b0;
        if (sd_init_done)
            sd_init_seen<=1'b1;
        write_finish_sync<={write_finish_sync[1:0],write_finish_toggle};
        if (!sd_init_qualified) begin
            scan_kicked<=1'b0; media_count<=3'd0; source_complete<=1'b0;
            load_started<=1'b0;
            write_toggle_baseline<=write_finish_sync[2];
            write_complete_pending<=1'b0;
        end
        else begin
            if (!scan_kicked && bmp_ready) begin
                scan_start<=1'b1; scan_kicked<=1'b1; media_count<=3'd0;
            end
            if (scan_found_valid && media_count<SCAN_TARGET_COUNT) begin
                case(media_count)
                    3'd0: media_sector0<=scan_found_sector;
                    3'd1: media_sector1<=scan_found_sector;
                    3'd2: media_sector2<=scan_found_sector;
                    default: media_sector3<=scan_found_sector;
                endcase
                media_count<=media_count+3'd1;
            end
            if (!load_inflight) begin
                // Start every request with fresh completion state.  This also
                // prevents a delayed event from a previous frame being reused.
                source_complete <= 1'b0;
                load_started <= 1'b0;
                write_complete_pending <= 1'b0;
            end else begin
                // A new request is considered active only after bmp_read has
                // left ST_IDLE.  Without this guard, its pre-request ready=1
                // level can be mistaken for source completion.
                if (!bmp_ready)
                    load_started <= 1'b1;
                if (load_started && bmp_ready)
                    source_complete <= 1'b1;

                // Consume the completion event exactly once when the session
                // controller accepts frame_commit; otherwise retain it until
                // the source side has completed.
                if (frame_commit) begin
                    write_complete_pending <= 1'b0;
                    write_toggle_baseline <= write_finish_sync[2];
                end else if (write_complete) begin
                    write_complete_pending <= 1'b1;
                    write_toggle_baseline <= write_finish_sync[2];
                end
            end
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
    .load_start(load_start),.load_sector(selected_sector(load_media_index)),.sd_init_done(sd_init_qualified),
    .state_code(bmp_state_code),.bmp_width(bmp_width),.bmp_height(bmp_height),.write_req(write_req),
    .write_req_ack(write_req_ack),.sd_sec_read(sd_sec_read),.sd_sec_read_addr(sd_sec_read_addr),
    .sd_sec_read_data(sd_data_bmp),.sd_sec_read_data_valid(sd_valid_bmp),
    .sd_sec_read_end(sd_end_bmp),.bmp_data_wr_en(bmp_data_wr_en),.bmp_data(bmp_data)
);

fat32_wav_reader u_sd_audio_reader(
    .clk(clk), .rst(rst), .sd_init_done(sd_init_qualified), .enable(display_valid),
    .sd_sec_read(audio_sd_read), .sd_sec_read_addr(audio_sd_addr),
    .sd_data(sd_data_audio), .sd_data_valid(sd_valid_audio),
    .sd_sec_read_end(sd_end_audio), .fifo_we(audio_fifo_we), .fifo_din(audio_fifo_din_int),
    .fifo_full(audio_fifo_full), .audio_read_toggle(audio_read_toggle),
    .busy(audio_busy), .done(audio_done), .file_found(audio_file_found), .format_ok(audio_format_ok),
    .format_error(audio_format_error)
);

// Test substitution is explicit and never defines a second sd_card_top.
`ifdef MEDIA_STARTUP_MODEL
media_startup_sector_model u_sd(
`else
sd_card_top u_sd(
`endif
    .clk(clk),.rst(rst),.SD_nCS(SD_nCS),.SD_DCLK(SD_DCLK),.SD_MOSI(SD_MOSI),.SD_MISO(SD_MISO),
    .sd_init_done(sd_init_done),.sd_sec_read(sd_read_mux),.sd_sec_read_addr(sd_addr_mux),
    .sd_sec_read_data(sd_sec_read_data),.sd_sec_read_data_valid(sd_sec_read_data_valid),.sd_sec_read_end(sd_sec_read_end),
    .sd_sec_write(1'b0),.sd_sec_write_addr(32'd0),.sd_sec_write_data(8'd0),.sd_sec_write_data_req(),.sd_sec_write_end()
);
endmodule
