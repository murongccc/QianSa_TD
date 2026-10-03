// 独立游戏引擎；切换 input_mode 必须由会话控制器先停止并复位。
// 0=AUTO、1=TEST、2=外部四轨输入；3 按 TEST 处理。
module rhythm_game_engine #(parameter integer SHARED_VIEW=0,parameter integer BLOCK_QUEUE=0,parameter integer SCORE_DSP=0)(
    input wire view_capture, input wire [1:0] input_mode,
    input wire clk, input wire rst_n, input wire run,
    input wire signed [32:0] song_time, input wire signed [31:0] chart_offset,
    input wire [15:0] total_notes, input wire chart_eof,
    input wire note_valid, input wire [63:0] note_data, output wire note_ready,
    input wire event_valid, output wire event_ready,
    input wire signed [32:0] event_time,
    input wire [3:0] press_mask, input wire [3:0] release_mask, input wire [3:0] down_mask,
    output wire [3:0] head_valid, output wire [127:0] head_time,
    output wire [3:0] holding_mask,
    input wire [4:0] view_index, output wire view_valid,
    output wire [31:0] view_start, output wire [31:0] view_end,
    output wire result_valid, output wire [1:0] result_lane, output wire [1:0] result_grade,
    output wire [15:0] perfect_count, output wire [15:0] good_count,
    output wire [15:0] bad_count, output wire [15:0] miss_count,
    output wire [15:0] combo, output wire [15:0] max_combo,
    output wire [19:0] score, output wire done, output wire queue_overflow
);
    wire auto_valid, core_ready;
    wire signed [32:0] auto_time;
    wire [3:0] auto_press, auto_down;
    reg [1:0] auto_guard;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)auto_guard<=0;else if(!run || view_capture)auto_guard<=0;else auto_guard<={auto_guard[0],1'b1};
    end
    wire [1:0] auto_lane;
    wire [4:0] selected_view=(SHARED_VIEW && !view_capture) ? {auto_lane,3'd0} : view_index;
    wire use_auto=input_mode==2'd0;
    wire use_external=input_mode==2'd2;
    assign event_ready=use_external && core_ready;
    rhythm_auto_input #(.SERIAL_HEAD(SHARED_VIEW),.SERIAL_LATENCY(BLOCK_QUEUE ? 8 : 0)) auto_input(
        .serial_valid(view_valid),.serial_time(view_start),.serial_lane(auto_lane),.clk(clk),.rst_n(rst_n),.run(run && (!BLOCK_QUEUE || auto_guard[1])),.enable(use_auto),
        .song_time(song_time),.head_valid(head_valid),.head_time(head_time),.holding_mask(holding_mask),
        .event_valid(auto_valid),.event_ready(core_ready && use_auto),.event_time(auto_time),
        .press_mask(auto_press),.down_mask(auto_down));
    rhythm_judge_core #(.BLOCK_QUEUE(BLOCK_QUEUE),.SCORE_DSP(SCORE_DSP)) judge(
        .clk(clk),
        .rst_n(rst_n),
        .run(run),
        .song_time(song_time),
        .chart_offset(chart_offset),
        .total_notes(total_notes),
        .chart_eof(chart_eof),
        .note_valid(note_valid),
        .note_data(note_data),
        .note_ready(note_ready),
        .event_valid(use_auto ? auto_valid : (use_external && event_valid)),
        .event_ready(core_ready),
        .event_time(use_auto ? auto_time : event_time),
        .press_mask(use_auto ? auto_press : (use_external ? press_mask : 4'd0)),
        .release_mask(use_external ? release_mask : 4'd0),
        .down_mask(use_auto ? auto_down : (use_external ? down_mask : 4'd0)),
        .head_valid(head_valid),
        .head_time(head_time),
        .holding_mask(holding_mask),
        .view_index(selected_view),
        .view_valid(view_valid),
        .view_start(view_start),
        .view_end(view_end),
        .result_valid(result_valid),
        .result_lane(result_lane),
        .result_grade(result_grade),
        .perfect_count(perfect_count),
        .good_count(good_count),
        .bad_count(bad_count),
        .miss_count(miss_count),
        .combo(combo),
        .max_combo(max_combo),
        .score(score),
        .done(done),
        .queue_overflow(queue_overflow)
    );
endmodule
