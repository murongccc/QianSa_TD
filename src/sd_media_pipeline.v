// Independent SD media pipeline: a catalogue records discovered BMP files,
// while media_session_controller owns the playback policy and frame-slot state.
module sd_media_pipeline #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter [31:0] SCAN_START_SECTOR = 32'd0,
    parameter [31:0] SCAN_MAX_SECTOR = 32'd131071,
    parameter [2:0] SCAN_TARGET_COUNT = 3'd5,
    // Board builds use 640x480.  Parameters make the complete BMP/FIFO/
    // scaler/session path practical to exercise in a small RTL regression.
    parameter integer SCALER_OUT_WIDTH = 640,
    parameter integer SCALER_OUT_HEIGHT = 480,
    parameter integer ENABLE_RHYTHM = 0
)(
    input wire clk, input wire rst, input wire key_next, input wire key_auto,
    input wire [5:0] game_metadata_address,output wire [7:0] game_metadata_data,output wire game_metadata_valid,
    input wire game_clk,game_reset,game_enable,game_cancel,game_mode,freeze_media,
    input wire game_note_ready,output wire game_note_valid,output wire [63:0] game_note_data,
    output wire game_ready,game_cancelled,game_audio_eof,game_chart_eof,media_quiet,
    output wire [3:0] game_error,output wire [31:0] game_frames,game_audio_level,
    output wire [15:0] game_notes,output wire signed [31:0] game_offset,
    output wire [191:0] game_title,output wire [127:0] game_difficulty,
    input wire [2:0] uart_command_async, input wire uart_command_toggle_async,
    output wire [3:0] state_code, input wire [15:0] bmp_width, input wire [15:0] bmp_height,
    output wire [15:0] parsed_width, output wire [15:0] parsed_height,
    output wire parsed_top_down,
    output wire display_valid, input wire write_finish_toggle,
    input wire display_switch_applied_toggle_async,
    output wire display_switch_toggle,
    output wire auto_play_enabled,
    output wire [2:0] write_buf_idx, output wire [2:0] disp_buf_idx,
    output wire write_req, input wire write_req_ack, output wire write_en,
    output wire [31:0] write_data, input wire write_ready, output wire SD_nCS, output wire SD_DCLK,
    output wire SD_MOSI, input wire SD_MISO,
    output wire audio_fifo_we, output wire [31:0] audio_fifo_din,
    input wire audio_fifo_full, input wire audio_read_toggle,
    input wire audio_reader_enable, input wire audio_reader_reset,
    output wire audio_reader_busy, output wire audio_reader_done
);
wire session_ready;
wire sd_sec_read; wire [31:0] sd_sec_read_addr; wire [7:0] sd_sec_read_data;
// rst_sd 原先直接驱动本层所有异步复位端。这里把最终释放限定在本层：
// 断言仍然异步，撤销则在本地保持 16 个时钟并三级同步，避免顶层大扇出
// reset-removal 路径的极小裕量使 BMP/缩放器启动状态不确定。
wire rst_local;
reg [3:0] game_control_meta,game_control_sync;
always @(posedge clk or posedge rst_local)begin
    if(rst_local)begin game_control_meta<=0;game_control_sync<=0;end
    else begin game_control_meta<={freeze_media,game_mode,game_cancel,game_enable};game_control_sync<=game_control_meta;end
end

domain_reset_sync #(.COUNTER_WIDTH(5), .HOLD_CYCLES(16)) u_reset_local (
    .clk         (clk),
    .async_reset (rst),
    .reset       (rst_local)
);
wire sd_sec_read_data_valid, sd_sec_read_end, bmp_data_wr_en, sd_init_done, bmp_ready;
wire [3:0] bmp_state_code;
wire audio_sd_read; wire [31:0] audio_sd_addr;
wire audio_busy, audio_done, audio_file_found, audio_format_ok, audio_format_error;
wire [31:0] audio_fifo_din_int;
wire [31:0] audio_fifo_level;
// 1,024 stereo PCM frames at 48 kHz retain roughly 21.3 ms of playback.
// Below that point a new BMP sector may not delay the reader.
wire audio_urgent = audio_reader_enable && display_valid &&
                    (audio_fifo_level < 32'd1024);
wire sd_read_mux; wire [31:0] sd_addr_mux;
wire [7:0] sd_data_bmp = sd_sec_read_data;
wire [7:0] sd_data_audio = sd_sec_read_data;
wire sd_valid_bmp, sd_end_bmp, sd_valid_audio, sd_end_audio;
wire catalog_done, catalog_candidate_valid, catalog_volume_valid;
wire [31:0] catalog_first_cluster, catalog_file_size, catalog_fat_start, catalog_data_start;
wire [31:0] catalog_root_cluster;
wire [7:0] catalog_sectors_per_cluster;
wire [2:0] catalog_candidate_count;
wire catalog_sd_read; wire [31:0] catalog_sd_addr;
wire bmp_sd_read; wire [31:0] bmp_sd_addr;
wire catalog_sd_valid, catalog_sd_end, bmp_sd_valid, bmp_sd_end;
reg source_complete, load_started;
reg [2:0] media_count;
reg [2:0] write_finish_sync;
reg write_req_ack_meta, write_req_ack_sync;
reg write_toggle_baseline;
reg write_complete_pending;
reg sd_init_seen;
wire sd_init_qualified = sd_init_done | sd_init_seen;
wire load_start, load_inflight; wire [2:0] load_media_index;
wire write_complete = load_inflight && (write_finish_sync[2] != write_toggle_baseline);
// The SD source and SDRAM writer finish in unrelated clock domains.  The old
// one-cycle write_complete pulse had to coincide with source_complete; if it
// arrived first, frame_commit was missed permanently and load_inflight never
// cleared, which disabled both keys and automatic playback.  Keep the write
// completion pending until the current BMP source has also returned to ready.
wire frame_commit = load_inflight && source_complete && write_complete_pending;
wire [23:0] bmp_data;
wire bmp_pixel_valid, bmp_pixel_ready, bmp_pixel_last, bmp_frame_last;
wire [23:0] bmp_pixel_data;
wire bmp_load_failed;
wire source_fifo_full, source_fifo_empty, source_fifo_afull;
wire [9:0] source_fifo_wrusedw, source_fifo_rdusedw;
wire [31:0] source_fifo_dout;
wire source_fifo_valid;
wire scaler_src_ready, scaler_dst_valid, scaler_dst_last, scaler_dst_frame_last;
wire [23:0] scaler_dst_pixel;
wire [9:0] scaler_dst_x, scaler_dst_y;
wire scaler_busy, scaler_done;
reg scaler_started;
wire scaler_start = write_req_ack_sync && !scaler_started;
wire source_fifo_re = scaler_src_ready && source_fifo_valid;
wire scaler_dst_ready = write_ready;
// A 512-byte sector can contribute at most 171 RGB pixels.  Reserve that
// space before launching a sector so pixel_ready remains asserted throughout
// the transaction and no byte is dropped mid-sector.
wire source_fifo_write_ok = (source_fifo_wrusedw <= 10'd320);
wire load_abort = load_inflight && load_started && bmp_ready && (bmp_load_failed || !scaler_started);
wire catalog_release = load_inflight && (frame_commit || load_abort);
assign sd_sec_read = bmp_sd_read | catalog_sd_read;
assign sd_sec_read_addr = bmp_sd_read ? bmp_sd_addr : catalog_sd_addr;
assign catalog_sd_valid = sd_valid_bmp && catalog_sd_read;
assign catalog_sd_end = sd_end_bmp && catalog_sd_read;
assign bmp_sd_valid = sd_valid_bmp && bmp_sd_read;
assign bmp_sd_end = sd_end_bmp && bmp_sd_read;

assign write_en = scaler_dst_valid && scaler_dst_ready;
assign write_data = {scaler_dst_pixel,8'd0};
assign audio_fifo_din = audio_fifo_din_int;
assign audio_reader_busy = audio_busy;
assign audio_reader_done = audio_done;
// 8 explicitly reports a completed search with no BMP. The old UI silently
// fell back to idle (1). 9 reports WAV lookup completed without a match.
reg audio_not_found;
reg audio_bad_format;
reg audio_ok_seen;
always @(posedge clk or posedge rst_local) begin
    if (rst_local) begin
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
                    (catalog_done && media_count==0) ? 4'd8 :
                    bmp_load_failed ? 4'hd :
                    (load_inflight && bmp_ready && scaler_busy && !source_complete) ? 4'hb :
                    (load_inflight && source_complete && !write_complete_pending) ? 4'hc :
                    audio_not_found ? 4'd9 :
                    audio_bad_format ? 4'd7 :
                    audio_ok_seen ? 4'd6 :
                    (display_valid && audio_busy) ?
                    (audio_format_ok ? 4'd6 : (audio_file_found ? 4'd7 : 4'd5)) :
                    (!catalog_done || catalog_candidate_valid) ? 4'd2 :
                    // 目录扫描完成后的空闲码直接显示已经提交至 SDRAM 的
                    // 图片数（1..5）。此前固定显示 bmp_read 的空闲码 1，
                    // 无法区分“仅一张可切换图片”与“五张均已预装”。
                    // 若目录已交出更多候选但提交数较少，D 表示后续帧在
                    // BMP/缩放/SDRAM 提交链中被放弃，而非目录只找到一张。
                    (catalog_done && !catalog_candidate_valid &&
                     catalog_candidate_count > media_count) ? 4'hd :
                    (bmp_state_code == 4'd1 && media_count != 3'd0) ?
                    {1'b0, media_count} : bmp_state_code;

generate if(ENABLE_RHYTHM)begin: rhythm_resources
    wire clear_sd;wire [3:0] resource_error;
    assign game_error=(game_control_sync[2] && catalog_done && !catalog_volume_valid) ? 4'd2 : resource_error;
    domain_reset_sync #(.COUNTER_WIDTH(4),.HOLD_CYCLES(8)) clear_sync(
        .clk(clk),.async_reset(rst_local | game_reset),.reset(clear_sd));
    rhythm_sd_resources #(.REUSE_MEDIA(1)) resources(
        .metadata_address(game_metadata_address),.metadata_data(game_metadata_data),
        .clk(clk),.note_clk(game_clk),.rst(clear_sd),.enable(game_control_sync[0] && session_ready),
        .cancel(game_control_sync[1]),.game_mode(game_control_sync[2]),
        .volume_valid(catalog_volume_valid),.volume_fat_start(catalog_fat_start),.volume_data_start(catalog_data_start),
        .volume_root_cluster(catalog_root_cluster),.volume_sectors_per_cluster(catalog_sectors_per_cluster),
        .bmp_req(sd_sec_read),.bmp_addr(sd_sec_read_addr),.bmp_valid(sd_valid_bmp),.bmp_done(sd_end_bmp),
        .sd_req(sd_read_mux),.sd_addr(sd_addr_mux),.sd_data(sd_sec_read_data),.sd_valid(sd_sec_read_data_valid),.sd_done(sd_sec_read_end),
        .audio_fifo_we(audio_fifo_we),.audio_fifo_data(audio_fifo_din_int),.audio_fifo_full(audio_fifo_full),
        .audio_read_toggle(audio_read_toggle),.audio_fifo_level(audio_fifo_level),
        .note_ready(game_note_ready),.note_valid(game_note_valid),.note_data(game_note_data),
        .header_valid(game_metadata_valid),.song_frames(game_frames),.note_count(game_notes),.hold_count(),.offset_samples(game_offset),
        .title(game_title),.difficulty(game_difficulty),.resources_ready(game_ready),.cancelled(game_cancelled),
        .audio_eof(game_audio_eof),.chart_eof(game_chart_eof),.error_code(resource_error),
        .wav_busy(audio_busy),.wav_done(audio_done),.wav_found(audio_file_found),.wav_format_ok(audio_format_ok),.wav_format_error(audio_format_error));
end else begin: legacy_resources
    assign game_metadata_valid=0;assign game_metadata_data=0;
    assign game_note_valid=0;assign game_note_data=0;assign game_ready=0;assign game_cancelled=0;
    assign game_audio_eof=0;assign game_chart_eof=0;assign game_error=0;assign game_frames=0;assign game_notes=0;
    assign game_offset=0;assign game_title=0;assign game_difficulty=0;
    sd_sector_arbiter u_sd_arbiter (
        .chart_req(1'b0),.chart_addr(32'd0),.chart_valid(),.chart_done(),
        .clk(clk), .rst(rst_local), .bmp_req(sd_sec_read), .bmp_addr(sd_sec_read_addr),
        .audio_req(audio_sd_read), .audio_addr(audio_sd_addr), .audio_urgent(audio_urgent),
        .sd_req(sd_read_mux), .sd_addr(sd_addr_mux), .sd_valid(sd_sec_read_data_valid), .sd_done(sd_sec_read_end),
        .bmp_valid(sd_valid_bmp), .bmp_done(sd_end_bmp), .audio_valid(sd_valid_audio), .audio_done(sd_end_audio));
// 图片目录器已经解析同一卷；播放重启复用稳定元数据，避免重复引导扇区硬件。
fat32_wav_reader #(.USE_SHARED_VOLUME(1)) u_sd_audio_reader(
    .game_mode(1'b0),.cancel(1'b0),.song_frames(),.song_frames_valid(),.stream_eof(),.cancelled(),
    .clk(clk), .rst(rst_local | audio_reader_reset), .sd_init_done(sd_init_qualified),
    .enable(display_valid && audio_reader_enable),
    .sd_sec_read(audio_sd_read), .sd_sec_read_addr(audio_sd_addr),
    .sd_data(sd_data_audio), .sd_data_valid(sd_valid_audio),
    .sd_sec_read_end(sd_end_audio), .fifo_we(audio_fifo_we), .fifo_din(audio_fifo_din_int),
    .fifo_full(audio_fifo_full), .audio_read_toggle(audio_read_toggle),
    .audio_fifo_level(audio_fifo_level),
    .busy(audio_busy), .done(audio_done), .file_found(audio_file_found), .format_ok(audio_format_ok),
    .format_error(audio_format_error),
    .volume_valid(catalog_volume_valid), .volume_fat_start(catalog_fat_start),
    .volume_data_start(catalog_data_start), .volume_root_cluster(catalog_root_cluster),
    .volume_sectors_per_cluster(catalog_sectors_per_cluster)
);

end endgenerate
assign game_audio_level=audio_fifo_level;
assign media_quiet=session_ready && !sd_sec_read;

always @(posedge clk or posedge rst_local) begin
    if (rst_local) begin
        source_complete<=1'b0; load_started<=1'b0;
        write_finish_sync<=3'd0; write_toggle_baseline<=1'b0; write_complete_pending<=1'b0;
        write_req_ack_meta<=1'b0; write_req_ack_sync<=1'b0;
        sd_init_seen<=1'b0;
        media_count<=3'd0;
    end else begin
        write_req_ack_meta<=write_req_ack;
        write_req_ack_sync<=write_req_ack_meta;
        if (sd_init_done)
            sd_init_seen<=1'b1;
        write_finish_sync<={write_finish_sync[1:0],write_finish_toggle};
        if (!sd_init_qualified) begin
            media_count<=3'd0; source_complete<=1'b0;
            load_started<=1'b0;
            write_toggle_baseline<=write_finish_sync[2];
            write_complete_pending<=1'b0;
        end
        else begin
            if (frame_commit && media_count < SCAN_TARGET_COUNT)
                media_count <= media_count + 1'b1;
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
                if (scaler_done)
                    source_complete <= 1'b1;
                if (!bmp_ready)
                    load_started <= 1'b1;

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

media_session_controller #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.AUTO_PERIOD_SECONDS(3),.ENABLE_FREEZE(ENABLE_RHYTHM)) u_session (
    .freeze(game_control_sync[3]),.session_ready(session_ready),
    .clk(clk),.rst(rst_local),.key_next(key_next),.key_auto(key_auto),.scan_done(catalog_done),
    .uart_command_async(uart_command_async),.uart_command_toggle_async(uart_command_toggle_async),
    .candidate_valid(catalog_candidate_valid),
    .media_count(media_count),.loader_ready(bmp_ready),.frame_commit(frame_commit),.load_abort(load_abort),.load_start(load_start),
    .display_switch_applied_toggle_async(display_switch_applied_toggle_async),
    .load_media_index(load_media_index),.write_slot(write_buf_idx),.display_slot(disp_buf_idx),
    .display_switch_toggle(display_switch_toggle),
    .display_valid(display_valid),.auto_play_enabled(auto_play_enabled),.load_inflight(load_inflight)
);

bmp_read u_bmp_read(
    .clk(clk),.rst(rst_local),.ready(bmp_ready),.scan_start(1'b0),.scan_start_sector(SCAN_START_SECTOR),
    .scan_max_sector(SCAN_MAX_SECTOR),.scan_target_count(SCAN_TARGET_COUNT),.scan_done(),
    .scan_found_valid(),.scan_found_sector(),.scan_found_total(),
    .load_start(load_start),.load_sector(32'd0),.sd_init_done(sd_init_qualified),
    .state_code(bmp_state_code),.bmp_width(bmp_width),.bmp_height(bmp_height),.write_req(write_req),
    .parsed_width(parsed_width),.parsed_height(parsed_height),.parsed_top_down(parsed_top_down),
    .write_req_ack(write_req_ack_sync),.sd_sec_read(bmp_sd_read),.sd_sec_read_addr(bmp_sd_addr),
    .sd_sec_read_data(sd_data_bmp),.sd_sec_read_data_valid(bmp_sd_valid),
    .sd_sec_read_end(bmp_sd_end),.bmp_data_wr_en(bmp_data_wr_en),.bmp_data(bmp_data),
    .pixel_valid(bmp_pixel_valid), .pixel_ready(bmp_pixel_ready), .pixel_data(bmp_pixel_data),
    .pixel_last(bmp_pixel_last), .frame_last(bmp_frame_last), .load_failed(bmp_load_failed)
    , .sector_ready(source_fifo_write_ok), .load_file_mode(1'b1),
    .load_first_cluster(catalog_first_cluster), .load_file_size(catalog_file_size),
    .fat_start_sector(catalog_fat_start), .first_data_sector(catalog_data_start),
    .sectors_per_cluster(catalog_sectors_per_cluster)
);

fat32_bmp_catalog u_bmp_catalog(
    .clk(clk), .rst(rst_local), .sd_init_done(sd_init_qualified),
    .sd_sec_read(catalog_sd_read), .sd_sec_read_addr(catalog_sd_addr),
    .sd_sec_read_data_valid(catalog_sd_valid), .sd_sec_read_data(sd_data_bmp),
    .sd_sec_read_end(catalog_sd_end), .candidate_valid(catalog_candidate_valid),
    .candidate_first_cluster(catalog_first_cluster), .candidate_file_size(catalog_file_size),
    .fat_start_sector(catalog_fat_start), .first_data_sector(catalog_data_start),
    .sectors_per_cluster(catalog_sectors_per_cluster), .candidate_count(catalog_candidate_count),
    .candidate_release(catalog_release),
    .stop(media_count >= SCAN_TARGET_COUNT),
    .scan_done(catalog_done), .volume_valid(catalog_volume_valid),
    .volume_root_cluster(catalog_root_cluster)
);

// This is a single-clock FIFO: both BMP decoding and scaling execute in
// sd_card_clk (clk).  Its Show-Ahead mode makes dout valid before the first
// read request, which is required by the src_valid/src_ready handshake below.
// scaler_start clears stale pixels from a previous/aborted load before the
// first sector of the new BMP is admitted.
source_pixel_fifo_ip source_pixel_fifo (
    .srst(rst_local | scaler_start), .clk(clk),
    .we(bmp_pixel_valid && bmp_pixel_ready),
    .di({bmp_frame_last,bmp_pixel_last,bmp_pixel_data,6'b0}),
    .re(source_fifo_re), .dout(source_fifo_dout), .valid(source_fifo_valid),
    .full_flag(source_fifo_full), .empty_flag(source_fifo_empty),
    .afull(source_fifo_afull), .aempty(), .wrusedw(source_fifo_wrusedw), .rdusedw(source_fifo_rdusedw)
);
assign bmp_pixel_ready = !source_fifo_full;

bmp_bilinear_scaler #(
    .OUT_WIDTH(SCALER_OUT_WIDTH), .OUT_HEIGHT(SCALER_OUT_HEIGHT),
    .MAX_WIDTH(1920)
) u_scaler (
    .clk(clk), .rst(rst_local), .start(scaler_start), .abort(load_abort),
    .src_width(parsed_width), .src_height(parsed_height),
    .src_valid(source_fifo_valid), .src_pixel(source_fifo_dout[29:6]),
    .src_last(source_fifo_dout[30]), .src_frame_last(source_fifo_dout[31]),
    .src_ready(scaler_src_ready), .dst_ready(scaler_dst_ready),
    .dst_valid(scaler_dst_valid), .dst_pixel(scaler_dst_pixel),
    .dst_last(scaler_dst_last), .dst_frame_last(scaler_dst_frame_last),
    .dst_x(scaler_dst_x), .dst_y(scaler_dst_y), .busy(scaler_busy), .done(scaler_done)
);

always @(posedge clk or posedge rst_local) begin
    if (rst_local) scaler_started <= 1'b0;
    else if (!load_inflight) scaler_started <= 1'b0;
    else if (scaler_start) scaler_started <= 1'b1;
end

// Test substitution is explicit and never defines a second sd_card_top.
`ifdef MEDIA_STARTUP_MODEL
media_startup_sector_model u_sd(
`else
sd_card_top u_sd(
`endif
    .clk(clk),.rst(rst_local),.SD_nCS(SD_nCS),.SD_DCLK(SD_DCLK),.SD_MOSI(SD_MOSI),.SD_MISO(SD_MISO),
    .sd_init_done(sd_init_done),.sd_sec_read(sd_read_mux),.sd_sec_read_addr(sd_addr_mux),
    .sd_sec_read_data(sd_sec_read_data),.sd_sec_read_data_valid(sd_sec_read_data_valid),.sd_sec_read_end(sd_sec_read_end),
    .sd_sec_write(1'b0),.sd_sec_write_addr(32'd0),.sd_sec_write_data(8'd0),.sd_sec_write_data_req(),.sd_sec_write_end()
);
endmodule
