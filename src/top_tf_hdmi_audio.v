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

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
parameter [ADDR_BITS-1:0] FRAME_PIXELS = 307200;   // 640*480 words
parameter [ADDR_BITS-1:0] BUF0_ADDR = 0;
parameter [ADDR_BITS-1:0] BUF1_ADDR = FRAME_PIXELS;
parameter [ADDR_BITS-1:0] BUF2_ADDR = FRAME_PIXELS * 2;
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
wire [6:0]  seg_diag_underflow, seg_diag_mismatch;
reg  [1:0]  diag_page;
reg  [26:0] diag_page_count;
wire [15:0] diag_display_value;
reg  [15:0] underflow_count_meta, underflow_count_sync, underflow_count_previous;
reg  [15:0] underflow_count_display;
reg  [15:0] mismatch_count_meta, mismatch_count_sync, mismatch_count_previous;
reg  [15:0] mismatch_count_display;

wire        video_read_req;
wire        video_read_req_ack;
wire        video_read_en;
wire [31:0] video_read_data;
wire        video_read_fifo_empty;
wire        video_read_fifo_valid;
wire [8:0]  video_read_fifo_level;
wire [15:0] video_underflow_count;
wire        video_underflow_sticky;
wire [15:0] video_mismatch_count;
wire        video_mismatch_sticky;

wire        sd_card_write_en;
wire [31:0] sd_card_write_data;
wire        sd_card_write_req;
wire        sd_card_write_req_ack;
wire        sd_card_write_ready;
wire        frame_write_finish;
reg         frame_write_toggle_mem;

wire [1:0]  write_buf_idx;
wire [1:0]  disp_buf_idx;
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
wire [63:0] audio_spectrum_bands;
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
assign rst_audio_fifo = rst_sd | rst_video;

uart_command_control #(.CLK_HZ(50_000_000), .BAUD(115_200)) u_uart_command_control (
    .clk(clk), .rst(rst_clk), .uart_rxd(uart_rxd),
    .brightness_level(uart_brightness_level), .volume_level(uart_volume_level),
    .playback_command(uart_playback_command),
    .playback_command_toggle(uart_playback_command_toggle),
    .echo_valid(uart_echo_valid), .echo_data(uart_echo_data)
);

uart_echo_tx #(.CLK_HZ(50_000_000), .BAUD(115_200)) u_uart_echo_tx (
    .clk(clk), .rst(rst_clk), .data_valid(uart_echo_valid), .data(uart_echo_data), .uart_txd(uart_txd)
);

// KEY2 is the manual-next input.  It is synchronized and debounced in
// sd_card_clk, the domain that consumes the playback commands.

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
    .clk(sd_card_clk),.async_reset(rst_all),.reset(rst_sd)
);
domain_reset_sync #(.COUNTER_WIDTH(10),.HOLD_CYCLES(1024)) u_reset_mem(
    .clk(ext_mem_clk),.async_reset(rst_all),.reset(rst_mem)
);
domain_reset_sync #(.COUNTER_WIDTH(10),.HOLD_CYCLES(1024)) u_reset_video(
    .clk(video_clk),.async_reset(rst_all),.reset(rst_video)
);

// mem_clk 域把 write_finish 单拍转成 toggle，供 sd_card_clk 域可靠同步
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
    .CLK_FREQ_HZ       (100_000_000),
    .SCAN_START_SECTOR (32'd0),
    // Keep three discovered images in the three independent SDRAM frame
    // slots.  A target of one made the startup scan stop after the first BMP,
    // so the manual/automatic image switcher had nothing else to select.
    .SCAN_MAX_SECTOR   (32'd131071),
    .SCAN_TARGET_COUNT (3'd3)
) sd_media_pipeline_m0(
    .clk               (sd_card_clk),
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
assign diag_display_value = (diag_page == 2'd0) ? {2'b00, refresh_gap_sync} :
                            (diag_page == 2'd1) ? underflow_count_display :
                                                  mismatch_count_display;
seg_decoder seg_decoder_diag_0(.bin_data(diag_display_value[3:0]), .seg_data(seg_diag_0));
seg_decoder seg_decoder_diag_1(.bin_data(diag_display_value[7:4]), .seg_data(seg_diag_1));
seg_decoder seg_decoder_diag_2(.bin_data(diag_display_value[11:8]), .seg_data(seg_diag_2));
seg_decoder seg_decoder_diag_3(.bin_data(diag_display_value[15:12]), .seg_data(seg_diag_3));
seg_decoder seg_decoder_diag_underflow(.bin_data(4'hb), .seg_data(seg_diag_underflow));
seg_decoder seg_decoder_diag_mismatch(.bin_data(4'hd), .seg_data(seg_diag_mismatch));

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
        diag_page <= 2'd0;
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
        mismatch_count_meta <= video_mismatch_count;
        mismatch_count_sync <= mismatch_count_meta;
        mismatch_count_previous <= mismatch_count_sync;
        if (mismatch_count_sync == mismatch_count_previous)
            mismatch_count_display <= mismatch_count_sync;

        if (diag_page_count == 27'd99_999_999) begin
            diag_page_count <= 27'd0;
            if (diag_page == 2'd2)
                diag_page <= 2'd0;
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
    // 每两秒轮换：刷新间隔、FIFO 空读计数(b)、帧数据变化计数(d)。
    .seg_data_0        ({1'b1,seg_diag_3}),
    .seg_data_1        ({1'b1,seg_diag_2}),
    .seg_data_2        ({1'b1,seg_diag_1}),
    .seg_data_3        ({1'b1,seg_diag_0}),
    .seg_data_4        ({(diag_page == 2'd1) ? (underflow_count_display == 16'd0) :
                         (diag_page == 2'd2) ? (mismatch_count_display == 16'd0) : 1'b1,
                              (diag_page == 2'd0) ?
                                   (refresh_fault_sync ? seg_refresh_fault : 7'b1111_111) :
                               (diag_page == 2'd1) ? seg_diag_underflow : seg_diag_mismatch}),
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
    .read_finish       (),
    .read_addr_0       (BUF0_ADDR),
    .read_addr_1       (BUF1_ADDR),
    .read_addr_2       (BUF2_ADDR),
    .read_addr_3       ({ADDR_BITS{1'b0}}),
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

    .write_clk         (sd_card_clk),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_ready       (sd_card_write_ready),
    .write_finish      (frame_write_finish),
    .write_addr_0      (BUF0_ADDR),
    .write_addr_1      (BUF1_ADDR),
    .write_addr_2      (BUF2_ADDR),
    .write_addr_3      ({ADDR_BITS{1'b0}}),
    .write_addr_index  (write_buf_idx),
    .write_len         (FRAME_PIXELS),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .write_v_flip      (!bmp_source_top_down)
);

frame_read_monitor #(.FRAME_PIXELS(FRAME_PIXELS)) u_frame_read_monitor (
    .clk                (video_clk),
    .rst                (rst_video),
    .display_valid_async(display_valid),
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

audio_playback_control #(.CLK_FREQ_HZ(100_000_000), .DEBOUNCE_MS(20)) u_audio_playback_control (
    // Button pause/resume control is intentionally disabled; SW1 is the
    // only board control for the music run/stop function.
    .clk(sd_card_clk), .rst(rst_sd), .play_pause_key_n(1'b1), .run_switch(swkey1),
    .fifo_empty_async(audio_fifo_empty), .player_mode(audio_player_mode_sd),
    .reader_enable(audio_reader_enable_sd), .reader_reset(audio_reader_reset_sd)
);

audio_fifo_32x4096 u_audio_fifo (
    .rst(rst_audio_fifo), .di(audio_fifo_din), .clkw(sd_card_clk), .we(audio_fifo_we),
    .do(audio_fifo_dout), .clkr(video_clk), .re(audio_fifo_re),
    .empty_flag(audio_fifo_empty), .full_flag(audio_fifo_full)
);

pcm_audio_player #(.PIXEL_CLOCK_HZ(25_000_000), .SAMPLE_RATE_HZ(48_000)) u_pcm_audio_player (
    .clk(video_clk), .rst(rst_video), .fifo_dout(audio_fifo_dout), .fifo_empty(audio_fifo_empty),
    .fifo_re(audio_fifo_re), .audio_valid(audio_valid), .left_pcm(audio_left_data),
    .volume_level_async(uart_volume_level),
    .playback_mode_async(audio_player_mode_sd),
    .right_pcm(audio_right_data), .underrun(audio_underrun)
);

// Export reads from the video-clock FIFO port as a safe event into the
// SD-clock WAV reader.  This protects against a full FIFO mid-sector.
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video)
        audio_read_toggle <= 1'b0;
    else if (audio_fifo_re && !audio_fifo_empty)
        audio_read_toggle <= ~audio_read_toggle;
end

audio_spectrum_analyzer u_audio_spectrum_analyzer (
    .clk         (video_clk),
    .rst         (rst_video),
    .sample_valid(audio_valid),
    .sample_pcm  (audio_left_data),
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
    .ACTIVE_WIDTH  (640),
    .ACTIVE_HEIGHT (480)
) u_video_presentation (
    .clk                (video_clk),
    .rst                (rst_video),
    .display_valid      (display_valid),
    .display_slot_async (disp_buf_idx),
    .display_switch_toggle_async(display_switch_toggle_sd),
    .display_slot_applied_toggle(display_slot_applied_toggle_video),
    .brightness_level_async(uart_brightness_level),
    .image_brightness_async(image_brightness),
    .image_contrast_async(image_contrast),
    .image_sharpness_async(image_sharpness),
    .image_selected_async(image_selected),
    .image_select_toggle_async(image_select_toggle),
    .image_adjust_toggle_async(image_adjust_toggle),
    .spectrum_bands     (audio_spectrum_bands),
    .de                 (de),
    .vs                 (vs),
    .rgb_in             (vout_data_raw),
    .rgb_out            (vout_data_processed)
);

`ifdef IMAGE_RAW_BYPASS
assign vout_data = vout_data_raw;
assign axis_input_de = de;
assign axis_input_vs = vs;
`else
assign vout_data = vout_data_processed;
assign axis_input_de = presentation_de_d2;
assign axis_input_vs = presentation_vs_d2;
`endif

image_controls u_image_controls (
    .clk(clk), .rst(rst_clk), .key_inc_n(key3), .key_dec_n(key4),
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
