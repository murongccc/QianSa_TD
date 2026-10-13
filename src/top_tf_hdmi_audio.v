module top(
    input                       clk,
    input                       rst_n,
    input                       key2,           // KEY2: 手动下一张
    input                       key3,           // KEY3: 当前参数增加
    input                       key4,           // KEY4: 当前参数减少
    input                       swkey1,         // SW1: 音乐运行总使能
    input                       swkey2,         // SW2: 自动播放
    input                       swkey3,         // SW3: 参数选择 MSB
    input                       swkey4,         // SW4: 参数选择 LSB

    output [5:0]                seg_sel,
    output [7:0]                seg_data,

    // Board USB-UART bridge: FPGA RX=F12, FPGA TX=D12.
    input                       uart_rxd,
    output                      uart_txd,

    // CH9350 独立串口：J2 第 1 脚接模块 TX，第 2 脚接模块 RX。
    input                       touch_rxd,
    output                      touch_txd,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso
);

// 资源受限时关闭旧签名诊断，保留 FIFO 空读、刷新与反压诊断。
parameter integer VIDEO_SIGNATURE_DIAGNOSTICS = 0;
parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
parameter [ADDR_BITS-1:0] FRAME_PIXELS = 307200;   // 640*480 words
parameter [ADDR_BITS-1:0] BUF0_ADDR = 0;
parameter [ADDR_BITS-1:0] BUF1_ADDR = FRAME_PIXELS;
parameter [ADDR_BITS-1:0] BUF2_ADDR = FRAME_PIXELS * 2;
parameter [ADDR_BITS-1:0] BUF3_ADDR = FRAME_PIXELS * 3;
parameter [ADDR_BITS-1:0] BUF4_ADDR = FRAME_PIXELS * 4;
// 100 MHz SDRAM 手动刷新：25.0 us，取 2500 周期。
// 512 周期保护窗让已发起的 256-word burst 排空后再接受刷新。
localparam [13:0] SDRAM_REFRESH_INTERVAL_CYCLES = 14'd2500;
localparam [13:0] SDRAM_REFRESH_GUARD_CYCLES    = 14'd512;

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;
wire app_ref_req;
wire refresh_hold;
wire refresh_fault;
wire [13:0] refresh_max_gap_mem;

wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire hdmi_5x_clk;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data_raw;
wire [23:0] vout_data;
wire [23:0] vout_data_processed;
reg presentation_de_d1, presentation_de_d2;
reg presentation_vs_d1, presentation_vs_d2;
wire axis_input_de, axis_input_vs;
wire        display_valid;
wire        video_display_active;

wire [3:0]  state_code;
wire [15:0] bmp_source_width, bmp_source_height;
wire        bmp_source_top_down;
reg  [3:0]  state_code_display;
reg  [3:0]  state_code_meta, state_code_sync, state_code_previous;
wire [6:0]  seg_data_0;
reg  [13:0] refresh_gap_meta, refresh_gap_sync;
reg         refresh_fault_meta, refresh_fault_sync;
wire [6:0]  seg_refresh_fault;
wire [6:0]  seg_diag_0, seg_diag_1, seg_diag_2, seg_diag_3;
wire [6:0]  seg_diag_underflow, seg_diag_mismatch, seg_diag_source, seg_diag_memory, seg_diag_axis_stall;
reg  [2:0]  diag_page;
reg  [26:0] diag_page_count;
wire [15:0] diag_display_value;
reg  [15:0] underflow_count_meta, underflow_count_sync, underflow_count_previous;
reg  [15:0] underflow_count_display;
reg  [15:0] mismatch_count_meta, mismatch_count_sync, mismatch_count_previous;
reg  [15:0] mismatch_count_display;
reg  [15:0] source_mismatch_meta, source_mismatch_sync, source_mismatch_previous;
reg  [15:0] source_mismatch_display;
reg  [15:0] memory_mismatch_meta, memory_mismatch_sync, memory_mismatch_previous;
reg  [15:0] memory_mismatch_display;
// HDMI 核的 AXIS ready 是其唯一能直接反映输入端接收状态的信号。
// 帧 FIFO 的 b/d 正常但 HDMI 显示出现横线时，记录这里是否拒收过有效像素。
reg  [15:0] axis_backpressure_count;
reg  [15:0] axis_backpressure_meta, axis_backpressure_sync, axis_backpressure_previous;
reg  [15:0] axis_backpressure_display;

wire        video_read_req;
wire        video_read_req_ack;
wire        video_read_finish_mem;
wire        video_read_en;
wire [31:0] video_read_data;
wire        video_read_fifo_empty;
wire        video_read_fifo_valid;
wire [8:0]  video_read_fifo_level;
wire [15:0] video_underflow_count;
wire        video_underflow_sticky;
wire [15:0] video_mismatch_count;
wire        video_mismatch_sticky;
wire [15:0] video_output_mismatch_count;
wire        video_output_mismatch_sticky;
wire [15:0] sdram_return_mismatch_count;
wire        sdram_return_mismatch_sticky;

wire        sd_card_write_en;
wire [31:0] sd_card_write_data;
wire        sd_card_write_req;
wire        sd_card_write_req_ack;
wire        sd_card_write_ready;
wire        frame_write_finish;
reg         frame_write_toggle_mem;

wire [2:0]  write_buf_idx;
wire [2:0]  disp_buf_idx;
wire        display_switch_toggle_sd;
wire        display_slot_applied_toggle_video;
wire        auto_play_enabled_sd;
reg         auto_play_meta;
reg         auto_play_display;

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;

wire hs_0;
wire vs_0;
wire de_0;

// HDMI 1.4b audio input
wire        audio_valid;
wire [23:0] audio_left_data;
wire [23:0] audio_right_data;
wire [255:0] audio_spectrum_bands;
wire [639:0] audio_spectrum_bars;
wire [6:0] audio_spectrum_read_address;
wire [7:0] audio_spectrum_read_data;
wire audio_spectrum_read_valid,audio_spectrum_active;
wire [7:0] audio_spectrum_radius;
wire audio_fifo_we, audio_fifo_full, audio_fifo_empty, audio_fifo_re;
wire [31:0] audio_fifo_din, audio_fifo_dout;
wire audio_reader_busy, audio_reader_done, audio_underrun;
reg  audio_read_toggle;
wire [1:0] audio_player_mode_sd;
wire       audio_reader_enable_sd;
wire       audio_reader_reset_sd;
wire        acr_valid;
wire [19:0] acr_cts;
wire [19:0] acr_n;

wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;

wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;
// Declare reset before any instance uses it; otherwise Verilog creates an
// implicit net and TD reports HDL-7225 as a critical warning.
wire        rst_all;
wire        rst_clk;
wire        rst_sd;
wire        rst_mem;
wire        rst_video;
`ifdef HDMI_COLOR_SEQUENCE_DIAG
reg  [2:0]  hdmi_color_phase;
wire [23:0] hdmi_color_pattern = (hdmi_color_phase == 3'd0) ? 24'h000000 :
                                 (hdmi_color_phase == 3'd1) ? 24'hff0000 :
                                 (hdmi_color_phase == 3'd2) ? 24'h00ff00 :
                                 (hdmi_color_phase == 3'd3) ? 24'h0000ff :
                                 (hdmi_color_phase == 3'd4) ? 24'hffff00 :
                                 (hdmi_color_phase == 3'd5) ? 24'h00ffff :
                                 (hdmi_color_phase == 3'd6) ? 24'hff00ff : 24'hffffff;
// 每一可见行从黑色开始逐像素轮换八色，覆盖与帧内容无关的 RGB 编码组合。
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video || !de)
        hdmi_color_phase <= 3'd0;
    else
        hdmi_color_phase <= hdmi_color_phase + 1'b1;
end
`endif
wire [5:0] game_metadata_address;wire [7:0] game_metadata_data;wire game_metadata_valid;
reg metadata_meta,metadata_sync;
always @(posedge video_clk or posedge rst_video)begin
    if(rst_video)begin metadata_meta<=0;metadata_sync<=0;end
    else begin metadata_meta<=game_metadata_valid;metadata_sync<=metadata_meta;end
end
wire game_freeze,game_active,game_auto,game_clear,game_enable,game_cancel;
wire engine_reset,engine_run,engine_load,game_capture;
wire game_note_valid,game_note_ready;wire [63:0] game_note_data;
wire game_ready,game_cancelled,game_audio_eof,game_chart_eof,media_quiet;
wire [3:0] game_error,game_state,session_error;wire [31:0] resource_frames,game_fifo_level,song_frames;
wire [15:0] resource_notes,total_notes;wire signed [31:0] resource_offset,chart_offset;
wire [191:0] game_title;wire [127:0] game_difficulty;
wire signed [32:0] game_time;
wire [1:0] session_player_mode;
wire sample_emitted,sample_missing,prefetch_ready;wire [31:0] sample_index,emitted_count;
wire judge_done,queue_overflow,session_chart_eof;wire [19:0] game_score;
wire [15:0] game_combo,game_max_combo,game_p,game_g,game_b,game_m;
wire [4:0] game_view_index;wire game_view_valid;wire [31:0] game_view_start,game_view_end;
wire [3:0] game_holding;wire game_frame_active,game_pixel_on,game_pixel_light;wire [23:0] game_pixel_rgb;
wire        rst_audio_fifo;
wire [2:0]  uart_brightness_level;
wire [2:0]  uart_volume_level;
wire [6:0]  image_brightness, image_contrast, image_sharpness;
wire [1:0]  image_selected;
wire        image_select_toggle, image_adjust_toggle;
wire [2:0]  uart_playback_command;
wire        uart_playback_command_toggle;
wire        uart_echo_valid;
wire [7:0]  uart_echo_data;
// 统一复位：TF 图像链路 + SDRAM + HDMI 音视频链路。
assign rst_all = ~rst_n;
assign rst_audio_fifo = rst_sd | rst_video | game_clear;

uart_command_control #(.CLK_HZ(50_000_000), .BAUD(115_200)) u_uart_command_control (
    .clk(clk), .rst(rst_clk), .uart_rxd(uart_rxd),
    .brightness_level(uart_brightness_level), .volume_level(uart_volume_level),
    .playback_command(uart_playback_command),
    .playback_command_toggle(uart_playback_command_toggle),
    .echo_valid(uart_echo_valid), .echo_data(uart_echo_data)
);

// 触摸本阶段只解析与监视；原始坐标尚未标定，不进入四轨判定。
wire touch_update;
wire [3:0] touch_a_id, touch_b_id;
wire touch_a_down, touch_b_down;
wire [15:0] touch_a_x, touch_a_y, touch_b_x, touch_b_y;
wire [1:0] touch_press, touch_release;
wire [7:0] touch_sequence;
wire [15:0] touch_good, touch_checksum_error, touch_format_error, touch_sequence_gap;
wire [15:0] touch_timeout, touch_uart_error, touch_ack;
wire [39:0] touch_pixel_packet,touch_frame_packet;
wire touch_lane_valid,touch_lane_armed,touch_game_enable,touch_game_overflow,touch_game_fault;
wire [3:0] touch_lane_press,touch_lane_release,touch_lane_down;
wire touch_game_valid,touch_game_ready;
wire signed [32:0] touch_game_time;
wire [3:0] touch_game_press,touch_game_release,touch_game_down;
wire touch_lane_monitor_overflow;
// 会话运行的暂停/BUFFER/退场清空输入；渲染 capture 只反压事件，不清空。
touch_lane_input u_touch_lane_input(
    .clk(clk),.rst(rst_clk),.enable(touch_game_enable),.update_valid(touch_update),
    .a_id(touch_a_id),.a_down(touch_a_down),.a_x(touch_a_x),.a_y(touch_a_y),
    .b_id(touch_b_id),.b_down(touch_b_down),.b_x(touch_b_x),.b_y(touch_b_y),
    .event_valid(touch_lane_valid),.press_mask(touch_lane_press),.release_mask(touch_lane_release),
    .down_mask(touch_lane_down),.armed(touch_lane_armed));
touch_game_event_bridge u_touch_game_bridge(
    .src_clk(clk),.src_rst(rst_clk),.dst_clk(video_clk),.dst_rst(rst_video),
    .enable(engine_run && !engine_reset && !game_auto),.src_enable(touch_game_enable),
    .src_valid(touch_lane_valid),.src_press(touch_lane_press),.src_release(touch_lane_release),.src_down(touch_lane_down),
    .game_time(game_time),.event_valid(touch_game_valid),.event_ready(touch_game_ready),.event_time(touch_game_time),
    .press_mask(touch_game_press),.release_mask(touch_game_release),.down_mask(touch_game_down),
    .overflow(touch_game_overflow),.fault(touch_game_fault));
wire touch_map_request,touch_pixel_valid,touch_mapper_busy;
ch9350_touch_input u_touch_input (
    .clk(clk),.rst(rst_clk),.touch_rxd(touch_rxd),.touch_txd(touch_txd),.update_valid(touch_update),
    .a_id(touch_a_id),.a_down(touch_a_down),.a_x(touch_a_x),.a_y(touch_a_y),
    .b_id(touch_b_id),.b_down(touch_b_down),.b_x(touch_b_x),.b_y(touch_b_y),
    .press_mask(touch_press),.release_mask(touch_release),.frame_seq(touch_sequence),
    .good_count(touch_good),.checksum_error_count(touch_checksum_error),.format_error_count(touch_format_error),
    .sequence_gap_count(touch_sequence_gap),.timeout_count(touch_timeout),.uart_error_count(touch_uart_error),.ack_count(touch_ack)
);
touch_serial_monitor u_touch_monitor (
    .lane_valid(touch_lane_valid),.lane_down(touch_lane_down),.lane_press(touch_lane_press),.lane_release(touch_lane_release),
    .lane_fault(touch_game_overflow),.lane_monitor_overflow(touch_lane_monitor_overflow),
    .clk(clk),.rst(rst_clk),.update_valid(touch_update),
    .a_id(touch_a_id),.a_down(touch_a_down),.a_x(touch_a_x),.a_y(touch_a_y),
    .b_id(touch_b_id),.b_down(touch_b_down),.b_x(touch_b_x),.b_y(touch_b_y),
    .press_mask(touch_press),.release_mask(touch_release),.frame_seq(touch_sequence),
    .good_count(touch_good),.checksum_error_count(touch_checksum_error),.format_error_count(touch_format_error),
    .sequence_gap_count(touch_sequence_gap),.timeout_count(touch_timeout),.uart_error_count(touch_uart_error),.ack_count(touch_ack),
    .echo_valid(uart_echo_valid),.echo_data(uart_echo_data),.uart_txd(uart_txd),
    .monitor_drop_count(),.echo_drop_count()
);

touch_pixel_mapper #(.ATOMIC_OUTPUT(0)) u_touch_mapper(
    .clk(clk),.rst(rst_clk),.update_valid(touch_map_request || (touch_update && touch_mapper_busy)),
    .a_down(touch_a_down),.a_x(touch_a_x),.a_y(touch_a_y),
    .b_down(touch_b_down),.b_x(touch_b_x),.b_y(touch_b_y),.pixel_valid(touch_pixel_valid),.pixel_packet(touch_pixel_packet),.busy(touch_mapper_busy));
touch_frame_snapshot u_touch_frame_snapshot(
    .src_clk(clk),.src_rst(rst_clk),.src_packet(touch_pixel_packet),.sample_valid(touch_pixel_valid),.sample_request(touch_map_request),
    .dst_clk(video_clk),.dst_rst(rst_video),.frame_start(vs && !presentation_vs_d1),.frame_packet(touch_frame_packet));

// KEY2 is the manual-next input.  It is synchronized and debounced in
// the 50 MHz media domain that consumes the playback commands.

// 保持你原来的 TF / SDRAM / video 时钟
sys_pll sys_pll_m0(
    .refclk     (clk),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft),
    .reset      (rst_all)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk),
    .reset      (rst_all)
);

domain_reset_sync #(.COUNTER_WIDTH(10),.HOLD_CYCLES(1024)) u_reset_clk(
    .clk(clk),.async_reset(rst_all),.reset(rst_clk)
);
domain_reset_sync #(.COUNTER_WIDTH(10),.HOLD_CYCLES(1024)) u_reset_sd(
    .clk(clk),.async_reset(rst_all),.reset(rst_sd)
);
domain_reset_sync #(.COUNTER_WIDTH(10),.HOLD_CYCLES(1024)) u_reset_mem(
    .clk(ext_mem_clk),.async_reset(rst_all),.reset(rst_mem)
);
domain_reset_sync #(.COUNTER_WIDTH(10),.HOLD_CYCLES(1024)) u_reset_video(
    .clk(video_clk),.async_reset(rst_all),.reset(rst_video)
);

// mem_clk 域把 write_finish 单拍转成 toggle，供 50 MHz 媒体域可靠同步
always @(posedge ext_mem_clk or posedge rst_mem) begin
    if (rst_mem)
        frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

// Bring the playback-mode indicator safely into the 50 MHz display domain.
always @(posedge clk or posedge rst_clk) begin
    if (rst_clk) begin
        auto_play_meta    <= 1'b0;
        auto_play_display <= 1'b0;
    end else begin
        auto_play_meta    <= auto_play_enabled_sd;
        auto_play_display <= auto_play_meta;
    end
end

// ===================== TF 多图扫描与缓存（双缓冲） =====================
sd_media_pipeline #(
    .ENABLE_RHYTHM(1),
    .CLK_FREQ_HZ       (50_000_000),
    .SCAN_START_SECTOR (32'd0),
    // Keep five discovered images in five independent SDRAM frame slots.
    // A target of one made the startup scan stop after the first BMP,
    // so the manual/automatic image switcher had nothing else to select.
    .SCAN_MAX_SECTOR   (32'd131071),
    .SCAN_TARGET_COUNT (3'd5)
) sd_media_pipeline_m0(
    .game_metadata_address(game_metadata_address),.game_metadata_data(game_metadata_data),.game_metadata_valid(game_metadata_valid),
    .game_clk(video_clk),.game_reset(game_clear),.game_enable(game_enable),.game_cancel(game_cancel),.game_mode(game_active),.freeze_media(game_freeze),
    .game_note_ready(game_note_ready && engine_load && !game_capture),.game_note_valid(game_note_valid),.game_note_data(game_note_data),
    .game_ready(game_ready),.game_cancelled(game_cancelled),.game_audio_eof(game_audio_eof),.game_chart_eof(game_chart_eof),.media_quiet(media_quiet),
    .game_error(game_error),.game_frames(resource_frames),.game_audio_level(game_fifo_level),.game_notes(resource_notes),.game_offset(resource_offset),
    .game_title(),.game_difficulty(),
    .clk               (clk),
    .rst               (rst_sd),
    .key_next          (key2),
    .key_auto          (swkey2),
    .uart_command_async(uart_playback_command),
    .uart_command_toggle_async(uart_playback_command_toggle),
    .state_code        (state_code),
    .bmp_width         (16'd0),
    .bmp_height        (16'd0),
    .parsed_width      (bmp_source_width),
    .parsed_height     (bmp_source_height),
    .parsed_top_down   (bmp_source_top_down),
    .display_valid     (display_valid),
    .auto_play_enabled (auto_play_enabled_sd),

    .write_finish_toggle(frame_write_toggle_mem),
    .display_switch_applied_toggle_async(display_slot_applied_toggle_video),
    .display_switch_toggle(display_switch_toggle_sd),
    .write_buf_idx     (write_buf_idx),
    .disp_buf_idx      (disp_buf_idx),

    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_ready       (sd_card_write_ready),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .SD_nCS            (sd_ncs),
    .SD_DCLK           (sd_dclk),
    .SD_MOSI           (sd_mosi),
    .SD_MISO           (sd_miso),
    .audio_fifo_we     (audio_fifo_we), .audio_fifo_din(audio_fifo_din),
    .audio_fifo_full   (audio_fifo_full), .audio_read_toggle(audio_read_toggle),
    .audio_reader_enable(audio_reader_enable_sd),
    .audio_reader_reset(audio_reader_reset_sd),
    .audio_reader_busy(audio_reader_busy),
    .audio_reader_done (audio_reader_done)
);

seg_decoder seg_decoder_m0(
    .bin_data          (state_code_display),
    .seg_data          (seg_data_0)
);

seg_decoder seg_decoder_refresh_fault(.bin_data(4'he), .seg_data(seg_refresh_fault));
assign diag_display_value = (diag_page == 3'd0) ? {2'b00, refresh_gap_sync} :
                            (diag_page == 3'd1) ? underflow_count_display :
                            (diag_page == 3'd2) ? mismatch_count_display :
                            (diag_page == 3'd3) ? source_mismatch_display :
                            (diag_page == 3'd4) ? memory_mismatch_display :
                                                  axis_backpressure_display;
seg_decoder seg_decoder_diag_0(.bin_data(diag_display_value[3:0]), .seg_data(seg_diag_0));
seg_decoder seg_decoder_diag_1(.bin_data(diag_display_value[7:4]), .seg_data(seg_diag_1));
seg_decoder seg_decoder_diag_2(.bin_data(diag_display_value[11:8]), .seg_data(seg_diag_2));
seg_decoder seg_decoder_diag_3(.bin_data(diag_display_value[15:12]), .seg_data(seg_diag_3));
seg_decoder seg_decoder_diag_underflow(.bin_data(4'hb), .seg_data(seg_diag_underflow));
seg_decoder seg_decoder_diag_mismatch(.bin_data(4'hd), .seg_data(seg_diag_mismatch));
seg_decoder seg_decoder_diag_source(.bin_data(4'hf), .seg_data(seg_diag_source));
seg_decoder seg_decoder_diag_memory(.bin_data(4'hc), .seg_data(seg_diag_memory));
seg_decoder seg_decoder_diag_axis(.bin_data(4'ha), .seg_data(seg_diag_axis_stall));

// Show 0 while SD initialization is pending; hiding it as 1 made a dead SD
// transport indistinguishable from idle. Synchronize and accept only stable
// status samples; intermediate multi-bit transitions are diagnostic only.
always @(posedge clk or posedge rst_clk) begin
    if (rst_clk) begin
        state_code_meta <= 4'd0;
        state_code_sync <= 4'd0;
        state_code_previous <= 4'd0;
        state_code_display <= 4'd0;
        refresh_gap_meta <= 14'd0;
        refresh_gap_sync <= 14'd0;
        refresh_fault_meta <= 1'b0;
        refresh_fault_sync <= 1'b0;
        underflow_count_meta <= 16'd0;
        underflow_count_sync <= 16'd0;
        underflow_count_previous <= 16'd0;
        underflow_count_display <= 16'd0;
        mismatch_count_meta <= 16'd0;
        mismatch_count_sync <= 16'd0;
        mismatch_count_previous <= 16'd0;
        mismatch_count_display <= 16'd0;
        source_mismatch_meta <= 16'd0;
        source_mismatch_sync <= 16'd0;
        source_mismatch_previous <= 16'd0;
        source_mismatch_display <= 16'd0;
        memory_mismatch_meta <= 16'd0;
        memory_mismatch_sync <= 16'd0;
        memory_mismatch_previous <= 16'd0;
        memory_mismatch_display <= 16'd0;
        axis_backpressure_meta <= 16'd0;
        axis_backpressure_sync <= 16'd0;
        axis_backpressure_previous <= 16'd0;
        axis_backpressure_display <= 16'd0;
        diag_page <= 3'd0;
        diag_page_count <= 27'd0;
    end else begin
        state_code_meta <= state_code;
        state_code_sync <= state_code_meta;
        state_code_previous <= state_code_sync;
        if (state_code_sync == state_code_previous)
            state_code_display <= state_code_sync;
        // 仅用于数码管诊断；源信号在 ext_mem_clk 域产生。
        refresh_gap_meta <= refresh_max_gap_mem;
        refresh_gap_sync <= refresh_gap_meta;
        refresh_fault_meta <= refresh_fault;
        refresh_fault_sync <= refresh_fault_meta;
        // 视频域诊断计数只在连续两次同步采样一致时更新显示值。
        underflow_count_meta <= video_underflow_count;
        underflow_count_sync <= underflow_count_meta;
        underflow_count_previous <= underflow_count_sync;
        if (underflow_count_sync == underflow_count_previous)
            underflow_count_display <= underflow_count_sync;
        mismatch_count_meta <= video_output_mismatch_count;
        mismatch_count_sync <= mismatch_count_meta;
        mismatch_count_previous <= mismatch_count_sync;
        if (mismatch_count_sync == mismatch_count_previous)
            mismatch_count_display <= mismatch_count_sync;
        source_mismatch_meta <= video_mismatch_count;
        source_mismatch_sync <= source_mismatch_meta;
        source_mismatch_previous <= source_mismatch_sync;
        if (source_mismatch_sync == source_mismatch_previous)
            source_mismatch_display <= source_mismatch_sync;
        memory_mismatch_meta <= sdram_return_mismatch_count;
        memory_mismatch_sync <= memory_mismatch_meta;
        memory_mismatch_previous <= memory_mismatch_sync;
        if (memory_mismatch_sync == memory_mismatch_previous)
            memory_mismatch_display <= memory_mismatch_sync;
        axis_backpressure_meta <= axis_backpressure_count;
        axis_backpressure_sync <= axis_backpressure_meta;
        axis_backpressure_previous <= axis_backpressure_sync;
        if (axis_backpressure_sync == axis_backpressure_previous)
            axis_backpressure_display <= axis_backpressure_sync;

        if (diag_page_count == 27'd99_999_999) begin
            diag_page_count <= 27'd0;
            if (diag_page == 3'd5)
                diag_page <= 3'd0;
            else if (VIDEO_SIGNATURE_DIAGNOSTICS == 0 && diag_page == 3'd1)
                diag_page <= 3'd5;
            else
                diag_page <= diag_page + 1'b1;
        end else begin
            diag_page_count <= diag_page_count + 1'b1;
        end
    end
end

seg_scan seg_scan_m0(
    .clk               (clk),
    .rst_n             (~rst_clk),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data),
    // 每两秒轮换：刷新间隔、FIFO 空读计数(b)、最终 RGB 帧变化(d)、
    // FIFO 输出帧变化(F)、SDRAM 返回帧变化(C)、HDMI AXIS 反压计数(A)。
    .seg_data_0        ({1'b1,seg_diag_3}),
    .seg_data_1        ({1'b1,seg_diag_2}),
    .seg_data_2        ({1'b1,seg_diag_1}),
    .seg_data_3        ({1'b1,seg_diag_0}),
    .seg_data_4        ({(diag_page == 3'd1) ? (underflow_count_display == 16'd0) :
                         (diag_page == 3'd2) ? (mismatch_count_display == 16'd0) :
                         (diag_page == 3'd3) ? (source_mismatch_display == 16'd0) :
                         (diag_page == 3'd4) ? (memory_mismatch_display == 16'd0) :
                         (diag_page == 3'd5) ? (axis_backpressure_display == 16'd0) : 1'b1,
                              (diag_page == 3'd0) ?
                                   (refresh_fault_sync ? seg_refresh_fault : 7'b1111_111) :
                               (diag_page == 3'd1) ? seg_diag_underflow :
                               (diag_page == 3'd2) ? seg_diag_mismatch :
                               (diag_page == 3'd3) ? seg_diag_source :
                               (diag_page == 3'd4) ? seg_diag_memory : seg_diag_axis_stall}),
    // Decimal point lights while automatic playback is enabled (active-low DP).
    .seg_data_5        ({~auto_play_display,seg_data_0})
);

// ===================== 原图像时序与帧缓存 =====================
video_timing_data video_timing_data_m0(
    .video_clk         (video_clk),
    .rst               (rst_video),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0)
);

video_delay video_delay_m0(
    .video_clk         (video_clk),
    .rst               (rst_video),
    .read_en           (video_read_en),
    .read_data         (video_read_data[31:8]),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0),
    .hs_r              (hs),
    .vs_r              (vs),
    .de_r              (de),
    .vout_data         (vout_data_raw)
);

sdram_refresh_scheduler #(
    .REFRESH_INTERVAL_CYCLES(SDRAM_REFRESH_INTERVAL_CYCLES),
    .EARLY_GUARD_CYCLES     (SDRAM_REFRESH_GUARD_CYCLES)
) u_sdram_refresh_scheduler(
    .clk               (ext_mem_clk),
    .rst               (rst_mem),
    .sdr_init_done     (Sdr_init_done),
    .sdr_init_ref_vld  (Sdr_init_ref_vld),
    .app_ref_req       (app_ref_req),
    .refresh_hold      (refresh_hold),
    .refresh_fault     (refresh_fault),
    .refresh_max_gap   (refresh_max_gap_mem)
);

frame_read_write #(
    .MEM_DATA_BITS    (MEM_DATA_BITS),
    .ADDR_BITS        (ADDR_BITS),
    .WRITE_V_FLIP     (1),
    .FRAME_WIDTH      (640),
    .FRAME_HEIGHT     (480)
) frame_read_write_m0(
    .mem_clk           (ext_mem_clk),
    .rst               (rst_mem),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .refresh_hold      (refresh_hold),

    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout),

    .read_clk          (video_clk),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .read_finish       (video_read_finish_mem),
    .read_addr_0       (BUF0_ADDR),
    .read_addr_1       (BUF1_ADDR),
    .read_addr_2       (BUF2_ADDR),
    .read_addr_3       (BUF3_ADDR),
    .read_addr_4       (BUF4_ADDR),
    .read_addr_index   (disp_buf_idx),
    .read_len          (FRAME_PIXELS),
    .read_en           (video_read_en),
    .read_data         (video_read_data),
    .read_fifo_empty   (video_read_fifo_empty),
    .read_fifo_valid   (video_read_fifo_valid),
    .read_fifo_level   (video_read_fifo_level),

    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_din        (App_wr_din),
    .App_wr_dm         (App_wr_dm),

    .write_clk         (clk),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_ready       (sd_card_write_ready),
    .write_finish      (frame_write_finish),
    .write_addr_0      (BUF0_ADDR),
    .write_addr_1      (BUF1_ADDR),
    .write_addr_2      (BUF2_ADDR),
    .write_addr_3      (BUF3_ADDR),
    .write_addr_4      (BUF4_ADDR),
    .write_addr_index  (write_buf_idx),
    .write_len         (FRAME_PIXELS),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .write_v_flip      (!bmp_source_top_down)
);

frame_read_monitor #(.FRAME_PIXELS(FRAME_PIXELS),.SIGNATURE_CHECK(VIDEO_SIGNATURE_DIAGNOSTICS)) u_frame_read_monitor (
    .clk                (video_clk),
    .rst                (rst_video),
    // 只统计视频域启动保护已放行的帧，忽略 SDRAM/FIFO 预热阶段。
    .display_valid_async(video_display_active),
    .display_slot_async (disp_buf_idx),
    .vs                 (vs),
    .fifo_read_req      (video_read_en),
    .fifo_empty         (video_read_fifo_empty),
    .fifo_valid         (video_read_fifo_valid),
    .fifo_data          (video_read_data),
    .underflow_count    (video_underflow_count),
    .underflow_sticky   (video_underflow_sticky),
    .mismatch_count     (video_mismatch_count),
    .mismatch_sticky    (video_mismatch_sticky)
);

generate
if (VIDEO_SIGNATURE_DIAGNOSTICS != 0) begin : g_video_signature_diagnostics
sdram_read_monitor #(.FRAME_PIXELS(FRAME_PIXELS)) u_sdram_read_monitor (
    .clk                (ext_mem_clk),
    .rst                (rst_mem),
    .frame_start        (video_read_req_ack),
    .frame_finish       (video_read_finish_mem),
    .data_valid         (Sdr_rd_en),
    .data               (Sdr_rd_dout),
    .mismatch_count     (sdram_return_mismatch_count),
    .mismatch_sticky    (sdram_return_mismatch_sticky)
);

// 直接校验 video_delay 送往 HDMI 的 RGB，而不是仅校验 FIFO 输出。
// 此计数可区分内部像素链错误与 HDMI 物理输出错误。
frame_read_monitor #(.FRAME_PIXELS(FRAME_PIXELS)) u_video_output_monitor (
    .clk                (video_clk),
    .rst                (rst_video),
    .display_valid_async(video_display_active),
    .display_slot_async (disp_buf_idx),
    .vs                 (vs),
    .fifo_read_req      (de),
    .fifo_empty         (1'b0),
    .fifo_valid         (de),
    .fifo_data          ({vout_data_raw, 8'd0}),
    .underflow_count    (),
    .underflow_sticky   (),
    .mismatch_count     (video_output_mismatch_count),
    .mismatch_sticky    (video_output_mismatch_sticky)
);
end else begin : g_without_video_signatures
    assign sdram_return_mismatch_count=16'd0;
    assign sdram_return_mismatch_sticky=1'b0;
    assign video_output_mismatch_count=16'd0;
    assign video_output_mismatch_sticky=1'b0;
end
endgenerate

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (rst_mem),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_ref_req       (app_ref_req),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// ===================== WAV PCM audio =====================

rhythm_session_controller u_game_session(
    .clk(video_clk),.rst(rst_video),.game_switch(swkey3 && swkey4),.run_switch(swkey1),
    .restart_key_n(key2),.pause_key_n(key3),.mode_key_n(1'b1),
    .media_quiet_async(media_quiet),.resources_ready_async(game_ready),.cancelled_async(game_cancelled),
    .audio_eof_async(game_audio_eof),.chart_eof_async(game_chart_eof),.error_async(game_error),
    .frames_async(resource_frames),.fifo_level_async(game_fifo_level),.notes_async(resource_notes),.offset_async(resource_offset),
    .sample_emitted(sample_emitted),.sample_missing(sample_missing),.prefetch_ready(prefetch_ready),.sample_index(sample_index),.emitted_count(emitted_count),
    .judge_done(judge_done),.queue_overflow(queue_overflow || touch_game_fault),.freeze_media(game_freeze),.active_game(game_active),.auto_mode(game_auto),
    .resource_reset(game_clear),.resource_enable(game_enable),.resource_cancel(game_cancel),.engine_reset(engine_reset),.engine_run(engine_run),.engine_load(engine_load),
    .player_mode(session_player_mode),.song_time(game_time),.song_frames(song_frames),.total_notes(total_notes),.chart_offset(chart_offset),
    .chart_eof(session_chart_eof),.state(game_state),.error_code(session_error));
// 单一会话控制器替代旧媒体音频控制，确保切换时整扇区安全退场。
assign audio_player_mode_sd=2'd0;
assign audio_reader_enable_sd=1'b0;
assign audio_reader_reset_sd=1'b0;

rhythm_game_engine #(.SHARED_VIEW(1),.BLOCK_QUEUE(1),.SCORE_DSP(1)) u_game_engine(
    .view_capture(game_capture),
    // 游戏固定为外部四轨手动输入，综合时移除 AUTO 事件发生器。
    .input_mode(2'd2),.clk(video_clk),.rst_n(!engine_reset),.run(engine_run && !game_capture),
    .song_time(game_time),.chart_offset(chart_offset),.total_notes(total_notes),.chart_eof(session_chart_eof),
    .note_valid(game_note_valid && engine_load && !game_capture),.note_data(game_note_data),.note_ready(game_note_ready),
    .event_valid(touch_game_valid),.event_ready(touch_game_ready),.event_time(touch_game_time),
    .press_mask(touch_game_press),.release_mask(touch_game_release),.down_mask(touch_game_down),
    .head_valid(),.head_time(),.holding_mask(game_holding),.view_index(game_view_index),.view_valid(game_view_valid),.view_start(game_view_start),.view_end(game_view_end),
    .result_valid(),.result_lane(),.result_grade(),.perfect_count(game_p),.good_count(game_g),.bad_count(game_b),.miss_count(game_m),
    .combo(game_combo),.max_combo(game_max_combo),.score(game_score),.done(judge_done),.queue_overflow(queue_overflow));
rhythm_game_renderer #(.BLOCK_GEOMETRY(1),.STREAM_METADATA(1),.BLOCK_HUD(1)) u_game_renderer(
    .input_down(touch_game_down),.input_press(touch_game_press & {4{touch_game_valid && touch_game_ready}}),
    .metadata_valid(metadata_sync),.metadata_address(game_metadata_address),.metadata_data(game_metadata_data),
    .clk(video_clk),.rst(rst_video | game_clear),.enabled(game_active),.de(de),.vs(vs),.song_time(game_time),.song_frames(song_frames),
    .state(game_state),.error_code(session_error),.auto_mode(game_auto),.score(game_score),.combo(game_combo),.max_combo(game_max_combo),
    .perfect_count(game_p),.good_count(game_g),.bad_count(game_b),.miss_count(game_m),.title(192'd0),.difficulty(128'd0),
    .view_index(game_view_index),.view_valid(game_view_valid),.view_start(game_view_start),.view_end(game_view_end),.holding_mask(game_holding),
    .capture_busy(game_capture),.frame_enabled(game_frame_active),.pixel_on(game_pixel_on),.pixel_light(game_pixel_light),.pixel_rgb(game_pixel_rgb));

audio_fifo_32x4096 u_audio_fifo (
    .rst(rst_audio_fifo), .di(audio_fifo_din), .clkw(clk), .we(audio_fifo_we),
    .do(audio_fifo_dout), .clkr(video_clk), .re(audio_fifo_re),
    .empty_flag(audio_fifo_empty), .full_flag(audio_fifo_full)
);

pcm_audio_player #(.PIXEL_CLOCK_HZ(25_000_000), .SAMPLE_RATE_HZ(48_000),.PREFETCH_PAUSED(1)) u_pcm_audio_player (
    // 实际输出帧驱动游戏时间，HDMI 补零不推进。
    .sample_emitted(sample_emitted),.sample_missing(sample_missing),.sample_index(sample_index),.emitted_count(emitted_count),.prefetch_ready(prefetch_ready),
    .clk(video_clk), .rst(rst_video | game_clear), .fifo_dout(audio_fifo_dout), .fifo_empty(audio_fifo_empty),
    .fifo_re(audio_fifo_re), .audio_valid(audio_valid), .left_pcm(audio_left_data),
    .volume_level_async(uart_volume_level),
    .playback_mode_async(session_player_mode),
    .right_pcm(audio_right_data), .underrun(audio_underrun)
);

// Export reads from the video-clock FIFO port as a safe event into the
// SD-clock WAV reader.  This protects against a full FIFO mid-sector.
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video || game_clear)
        audio_read_toggle <= 1'b0;
    else if (audio_fifo_re && !audio_fifo_empty)
        audio_read_toggle <= ~audio_read_toggle;
end

// 2048 点在 48 kHz 下提供 23.4375 Hz 间隔；直接 FFT 插值显示至约 6.39 kHz。
audio_fft_spectrum #(.FFT_POINTS(2048), .REFERENCE_MODE(1),.BLOCK_BARS(1)) u_audio_fft_spectrum (
    .clk         (video_clk),
    .rst         (rst_video),
    .sample_valid(audio_valid),
    .sample_pcm  (audio_left_data),
    .frame_start (vs),
    .bars        (audio_spectrum_bars),
    .bars_read_address(audio_spectrum_read_address),.bars_read_data(audio_spectrum_read_data),
    .bars_read_valid(audio_spectrum_read_valid),.bars_active(audio_spectrum_active),
    .breath_radius(audio_spectrum_radius),
    .bands       (audio_spectrum_bands)
);

audio_arc_calculate #(
    .ACR_N         (6144)
) u_audio_arc_calculate (
    .I_clk         (video_clk),
    .I_rst         (rst_video),
    .I_audio_valid (audio_valid),
    .O_acr_valid   (acr_valid),
    .O_acr_cts     (acr_cts),
    .O_acr_n       (acr_n)
);

// ===================== Presentation layer and RGB/DE to AXIS =====================
video_presentation #(
    .ENABLE_RHYTHM(1),
    .ENABLE_TOUCH_MARKERS(1),
    .REFERENCE_SPECTRUM(1),
    .BLOCK_BARS(1),
    .ACTIVE_WIDTH  (640),
    .ACTIVE_HEIGHT (480)
) u_video_presentation (
    // 会话清理只关闭 UI；背景压暗由稳定的游戏会话状态控制。
    .game_active(game_active),.game_pixel_on(game_pixel_on),.game_pixel_light(game_pixel_light),.game_pixel_rgb(game_pixel_rgb),
    .touch_frame_packet(touch_frame_packet),
    .clk                (video_clk),
    .rst                (rst_video),
    .display_valid      (display_valid),
    .display_slot_async (disp_buf_idx),
    .display_switch_toggle_async(display_switch_toggle_sd),
    .display_slot_applied_toggle(display_slot_applied_toggle_video),
    .display_active      (video_display_active),
    .brightness_level_async(uart_brightness_level),
    .image_brightness_async(image_brightness),
    .image_contrast_async(image_contrast),
    .image_sharpness_async(image_sharpness),
    .image_selected_async(image_selected),
    .image_select_toggle_async(image_select_toggle),
    .image_adjust_toggle_async(image_adjust_toggle),
    .spectrum_bars      (audio_spectrum_bars),
    .spectrum_read_address(audio_spectrum_read_address),.spectrum_read_data(audio_spectrum_read_data),
    .spectrum_read_valid(audio_spectrum_read_valid),.spectrum_active(audio_spectrum_active),
    .spectrum_radius    (audio_spectrum_radius),
    .spectrum_bands     (audio_spectrum_bands),
    .de                 (de),
    .vs                 (vs),
    .rgb_in             (vout_data_raw),
    .rgb_out            (vout_data_processed)
);

// 恢复完整的图像呈现链：RGB、DE 和 VS 同步经过两拍处理后送入 HDMI AXIS。
assign vout_data = vout_data_processed;
assign axis_input_de = presentation_de_d2;
assign axis_input_vs = presentation_vs_d2;

image_controls #(.ENABLE_GAME_GUARD(1)) u_image_controls (
    .freeze(game_freeze || (swkey3 && swkey4)),.clk(clk), .rst(rst_clk), .key_inc_n(key3), .key_dec_n(key4),
    .sw_sel_b(swkey3), .sw_sel_a(swkey4),
    .brightness(image_brightness), .contrast(image_contrast), .sharpness(image_sharpness),
    .selected(image_selected), .select_toggle(image_select_toggle),
    .adjust_toggle(image_adjust_toggle)
);

// 显示处理包含两级像素寄存：调节/标记与锐化/叠加。
// DE/VS 同样延迟两拍，避免行首像素与控制信号错位。
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) begin
        presentation_de_d1 <= 1'b0; presentation_de_d2 <= 1'b0;
        presentation_vs_d1 <= 1'b0; presentation_vs_d2 <= 1'b0;
    end else begin
        presentation_de_d1 <= de; presentation_de_d2 <= presentation_de_d1;
        presentation_vs_d1 <= vs; presentation_vs_d2 <= presentation_vs_d1;
    end
end

video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_video),
    .I_vs          (axis_input_vs),
    .I_de          (axis_input_de),
    .I_rgb         (vout_data),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

// AXIS 源是等时视频流，不能因 ready 拉低而暂停像素时钟；因此这里仅
// 统计而不改变数据通路。若该计数增长，HDMI 核在有效像素期间拒收数据，
// 会直接解释 b/d 不变但画面出现短横线的现象。
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video)
        axis_backpressure_count <= 16'd0;
    else if (axis_s_valid && !axis_s_ready && axis_backpressure_count != 16'hffff)
        axis_backpressure_count <= axis_backpressure_count + 1'b1;
end

// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (rst_video),
    .O_pulse (edid_trig)
);

// ===================== 带音频的 HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 800        ),
    .HSA                    ( 96         ),
    .HFP                    ( 16         ),
    .HBP                    ( 48         ),
    .HACTIVE                ( 640        ),
    .VTOTAL                 ( 525        ),
    .VSA                    ( 2          ),
    .VFP                    ( 10         ),
    .VBP                    ( 33         ),
    .VACTIVE                ( 480        ),
    .VIDEO_VIC              ( 1          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 250        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (rst_video),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (audio_valid),
    .I_audio_left_data  (audio_left_data),
    .I_audio_right_data (audio_right_data),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (rst_video),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule

// 在 SDRAM 返回口处逐帧签名。用于区分控制器返回数据变化与后级异步 FIFO 问题。
module sdram_read_monitor #(
    parameter integer FRAME_PIXELS = 307200
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        frame_start,
    input  wire        frame_finish,
    input  wire        data_valid,
    input  wire [31:0] data,
    output reg  [15:0] mismatch_count,
    output reg         mismatch_sticky
);

localparam [18:0] EXPECTED_WORDS = FRAME_PIXELS;

reg        active;
reg [18:0] word_count;
reg [31:0] frame_signature;
reg [31:0] baseline_signature;
reg        baseline_valid;
// frame_start 来自请求/应答握手。read_req_ack 在 S_ACK 状态会保持多个
// mem_clk，故必须边沿化；直接把其电平作为开始条件会重复清空本帧签名。
reg        frame_start_d;

wire frame_start_pulse = frame_start && !frame_start_d;

wire [31:0] signature_next = {frame_signature[30:0], frame_signature[31]} ^
                             data ^ {13'd0, word_count};

always @(posedge clk or posedge rst) begin
    if (rst) begin
        active             <= 1'b0;
        word_count         <= 19'd0;
        frame_signature    <= 32'd0;
        baseline_signature <= 32'd0;
        baseline_valid     <= 1'b0;
        frame_start_d      <= 1'b0;
        mismatch_count     <= 16'd0;
        mismatch_sticky    <= 1'b0;
    end else begin
        frame_start_d <= frame_start;
        if (frame_start_pulse) begin
            active          <= 1'b1;
            word_count      <= 19'd0;
            frame_signature <= 32'd0;
        end else begin
            if (active && data_valid) begin
                frame_signature <= signature_next;
                if (word_count != 19'h7ffff)
                    word_count <= word_count + 1'b1;
            end

            if (frame_finish && active) begin
                active <= 1'b0;
                if (word_count != EXPECTED_WORDS) begin
                    mismatch_sticky <= 1'b1;
                    if (mismatch_count != 16'hffff)
                        mismatch_count <= mismatch_count + 1'b1;
                end else if (!baseline_valid) begin
                    baseline_signature <= frame_signature;
                    baseline_valid <= 1'b1;
                end else if (frame_signature != baseline_signature) begin
                    mismatch_sticky <= 1'b1;
                    if (mismatch_count != 16'hffff)
                        mismatch_count <= mismatch_count + 1'b1;
                end
            end
        end
    end
end

endmodule
