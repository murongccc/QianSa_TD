// 第二阶段可复用加载组件：共享卷、三客户端扇区仲裁、游戏 WAV 与谱面预取。
// 除 note_* 在 note_clk 域外，全部状态/元数据属于 clk（SD 域）。元数据在
// header_valid 后稳定至 rst；会话控制以同步 valid 和保持总线跨域锁存。
// rst 仅用于硬复位或两个读取器 cancelled 后的会话清理；cancel 不清缓存。
module rhythm_sd_resources #(parameter integer REUSE_MEDIA=0)(
    input wire clk, input wire note_clk, input wire rst, input wire enable, input wire cancel,
    input wire [5:0] metadata_address,output wire [7:0] metadata_data,
    input wire game_mode,
    input wire volume_valid,
    input wire [31:0] volume_fat_start,volume_data_start,volume_root_cluster,
    input wire [7:0] volume_sectors_per_cluster,
    input wire bmp_req,input wire [31:0] bmp_addr,
    output wire bmp_valid,output wire bmp_done,output wire [7:0] bmp_data,output wire response_busy,
    output wire sd_req,output wire [31:0] sd_addr,
    input wire [7:0] sd_data,input wire sd_valid,input wire sd_done,
    output wire audio_fifo_we,output wire [31:0] audio_fifo_data,
    input wire audio_fifo_full,input wire audio_read_toggle,
    output wire [31:0] audio_fifo_level,
    input wire note_ready,output wire note_valid,output wire [63:0] note_data,
    output wire header_valid,output wire [31:0] song_frames,
    output wire [15:0] note_count,hold_count,
    output wire signed [31:0] offset_samples,
    output wire [191:0] title,output wire [127:0] difficulty,
    output wire resources_ready,output wire cancelled,
    output wire wav_busy,wav_done,wav_found,wav_format_ok,wav_format_error,
    output wire audio_eof,output wire chart_eof,output wire [3:0] error_code
);
    wire game_session=REUSE_MEDIA ? game_mode : 1'b1;
    wire chart_req,audio_req,chart_valid,chart_done,audio_valid,audio_done;
    wire [31:0] chart_addr,audio_addr;
    wire metadata_we;wire [5:0] metadata_write_address;wire [7:0] metadata_write_data;
    wire note_we,reserve_ready,overflow;
    wire [63:0] note_write_data;
    wire [7:0] chart_used;
    wire chart_cancelled,audio_cancelled,wav_bad,wav_frames_valid;
    wire [31:0] wav_frames;
    wire [3:0] chart_error;
    wire [2:0] wav_error_detail;
    reg wav_missing;
    always @(posedge clk or posedge rst)begin
        if(rst)wav_missing<=0;
        else if(wav_done && !wav_found && !cancel)wav_missing<=1;
    end
    assign wav_format_error=wav_bad;
    // 共享端口可能还有 BMP 事务；总线空闲才允许会话复位。
    assign cancelled=chart_cancelled && audio_cancelled && !response_busy;
    wire frame_count_mismatch=header_valid && wav_frames_valid && song_frames!=wav_frames;
    // 就绪只需要是否存在错误，不经过四位错误码的优先选择及零值译码。
    // 保留错误码优先级，直接并行合并相同错误条件，响应时机保持不变。
    wire resources_error=game_session && (chart_error!=4'd0 || overflow ||
        wav_missing || wav_bad || frame_count_mismatch);
    assign error_code=!game_session ? 4'd0 : chart_error!=0 ? chart_error : overflow ? 4'd6 :
        wav_missing ? 4'd7 : wav_bad ?
        (wav_error_detail==3'd1 ? 4'd11 : wav_error_detail==3'd2 ? 4'd12 :
         wav_error_detail==3'd3 ? 4'd13 : wav_error_detail==3'd4 ? 4'd14 : 4'd8) :
        frame_count_mismatch ? 4'd9 : 4'd0;
    wire startup_ready=(!game_session ? (enable && audio_fifo_level>=2048) : (!resources_error && !cancel && !cancelled && header_valid && wav_frames_valid &&
        (chart_used>=64 || (chart_eof && chart_used!=0)) &&
        (audio_fifo_level>=2048 || (audio_eof && audio_fifo_level!=0))));
    reg ready_latched;
    always @(posedge clk or posedge rst)begin
        if(rst)ready_latched<=0;else if(startup_ready)ready_latched<=1;
    end
    assign resources_ready=ready_latched && !cancel && !cancelled && !resources_error;
    sd_sector_arbiter #(.ENABLE_CHART(1),.REGISTER_RESPONSE(1)) u_arbiter(
        .sd_data(sd_data),.response_data(bmp_data),.response_busy(response_busy),
        .clk(clk),.rst(rst),.bmp_req(bmp_req),.bmp_addr(bmp_addr),
        .audio_req(audio_req),.audio_addr(audio_addr),.audio_urgent(audio_fifo_level<1024),
        .chart_req(chart_req),.chart_addr(chart_addr),.chart_valid(chart_valid),.chart_done(chart_done),
        .sd_req(sd_req),.sd_addr(sd_addr),.sd_valid(sd_valid),.sd_done(sd_done),
        .bmp_valid(bmp_valid),.bmp_done(bmp_done),.audio_valid(audio_valid),.audio_done(audio_done));
    generate if(REUSE_MEDIA)begin: metadata_ram
        rhythm_block_ram ram(.write_clk(clk),.write_enable(metadata_we),.write_address(metadata_write_address),.write_data(metadata_write_data),
            .read_clk(note_clk),.read_address(metadata_address),.read_data(metadata_data));
    end else begin assign metadata_data=0;end endgenerate
    fat32_chart_reader u_chart(
        .metadata_we(metadata_we),.metadata_address(metadata_write_address),.metadata_data(metadata_write_data),
        .clk(clk),.rst(rst),.enable(enable && game_session),.cancel(cancel),.volume_valid(volume_valid),
        .volume_fat_start(volume_fat_start),.volume_data_start(volume_data_start),
        .volume_root_cluster(volume_root_cluster),.volume_sectors_per_cluster(volume_sectors_per_cluster),
        .reserve_ready(reserve_ready),.sd_req(chart_req),.sd_addr(chart_addr),
        .sd_data(bmp_data),.sd_valid(chart_valid),.sd_done(chart_done),
        .note_we(note_we),.note_data(note_write_data),.header_valid(header_valid),.song_frames(song_frames),
        .note_count(note_count),.hold_count(hold_count),.offset_samples(offset_samples),
        .title(title),.difficulty(difficulty),.busy(),.eof(chart_eof),.cancelled(chart_cancelled),.error_code(chart_error));
    rhythm_chart_buffer u_buffer(
        .rst(rst),.write_clk(clk),.read_clk(note_clk),.write_enable(note_we),.write_data(note_write_data),
        .reserve_ready(reserve_ready),.write_used(chart_used),.overflow(overflow),
        .note_ready(note_ready),.note_valid(note_valid),.note_data(note_data));
    fat32_wav_reader #(.USE_SHARED_VOLUME(1),.ENABLE_GAME(1),.EXCLUDE_GAME_WAV(REUSE_MEDIA)) u_wav(
        .clk(clk),.rst(rst),.enable(enable),.sd_init_done(volume_valid),.game_mode(game_session),.cancel(cancel),
        .volume_valid(volume_valid),.volume_fat_start(volume_fat_start),.volume_data_start(volume_data_start),
        .volume_root_cluster(volume_root_cluster),.volume_sectors_per_cluster(volume_sectors_per_cluster),
        .sd_sec_read(audio_req),.sd_sec_read_addr(audio_addr),.sd_data(bmp_data),
        .sd_data_valid(audio_valid),.sd_sec_read_end(audio_done),.fifo_we(audio_fifo_we),.fifo_din(audio_fifo_data),
        .fifo_full(audio_fifo_full),.audio_read_toggle(audio_read_toggle),.audio_fifo_level(audio_fifo_level),
        .busy(wav_busy),.done(wav_done),.file_found(wav_found),.format_ok(wav_format_ok),.format_error(wav_bad),.format_error_detail(wav_error_detail),
        .song_frames(wav_frames),.song_frames_valid(wav_frames_valid),.stream_eof(audio_eof),.cancelled(audio_cancelled));
endmodule
