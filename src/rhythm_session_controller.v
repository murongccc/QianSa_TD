// 视频域统一音频会话。取消必须先等 SD 整扇区退场和图片提交，再清空共享资源。
module rhythm_session_controller #(
    parameter integer CLOCK_HZ=25_000_000,
    parameter integer DEBOUNCE_MS=20,
    parameter integer PREROLL_SAMPLES=96000,
    parameter integer TAIL_SAMPLES=7200
)(
    input wire clk,input wire rst,
    input wire game_switch,input wire run_switch,
    input wire restart_key_n,pause_key_n,mode_key_n,
    input wire media_quiet_async,resources_ready_async,cancelled_async,audio_eof_async,chart_eof_async,
    input wire [3:0] error_async,input wire [31:0] frames_async,fifo_level_async,
    input wire [15:0] notes_async,input wire signed [31:0] offset_async,
    input wire sample_emitted,sample_missing,prefetch_ready,
    input wire [31:0] sample_index,emitted_count,
    input wire judge_done,queue_overflow,
    output wire freeze_media,output reg active_game,output reg auto_mode,
    output wire resource_reset,resource_enable,resource_cancel,
    output wire engine_reset,engine_run,engine_load,
    output wire [1:0] player_mode,
    output reg signed [32:0] song_time,
    output reg [31:0] song_frames,output reg [15:0] total_notes,
    output reg signed [31:0] chart_offset,
    output wire chart_eof,output reg [3:0] state,output reg [3:0] error_code
);
    localparam RETIRE=4'd0,CLEAR=4'd1,STOP=4'd2,SETTLE=4'd3,LOAD=4'd4,
               PREROLL=4'd5,PLAY=4'd6,PAUSE=4'd7,BUFFER=4'd8,TAIL=4'd9,RESULT=4'd10,ERROR=4'd11;
    wire want_game,want_run,k2_level,k3_level,k4_level,k2,k3,k4;
    audio_control_debounce #(.CLK_FREQ_HZ(CLOCK_HZ),.DEBOUNCE_MS(DEBOUNCE_MS)) gsw(
        .clk(clk),.rst(rst),.async_in(game_switch),.stable_level(want_game),.fall_pulse());
    audio_control_debounce #(.CLK_FREQ_HZ(CLOCK_HZ),.DEBOUNCE_MS(DEBOUNCE_MS)) rsw(
        .clk(clk),.rst(rst),.async_in(run_switch),.stable_level(want_run),.fall_pulse());
    audio_control_debounce #(.CLK_FREQ_HZ(CLOCK_HZ),.DEBOUNCE_MS(DEBOUNCE_MS),.RESET_LEVEL(1)) key2(clk,rst,restart_key_n,k2_level,k2);
    audio_control_debounce #(.CLK_FREQ_HZ(CLOCK_HZ),.DEBOUNCE_MS(DEBOUNCE_MS),.RESET_LEVEL(1)) key3(clk,rst,pause_key_n,k3_level,k3);
    audio_control_debounce #(.CLK_FREQ_HZ(CLOCK_HZ),.DEBOUNCE_MS(DEBOUNCE_MS),.RESET_LEVEL(1)) key4(clk,rst,mode_key_n,k4_level,k4);
    reg keys_armed;
    reg [4:0] flags_meta,flags_sync;
    reg [3:0] err_meta,err_sync,err_previous;
    reg [31:0] frames_meta,frames_sync,level_meta,level_sync;
    reg [15:0] notes_meta,notes_sync;
    reg signed [31:0] offset_meta,offset_sync;
    wire quiet=flags_sync[4],ready=flags_sync[3],cancelled=flags_sync[2],audio_eof=flags_sync[1];
    assign chart_eof=flags_sync[0];
    function integer bits_for;
        input integer count;integer v;
        begin bits_for=1;for(v=count-1;v>1;v=v>>1)bits_for=bits_for+1;end
    endfunction
    localparam PHASE_BITS=bits_for(CLOCK_HZ+48000),PRE_BITS=bits_for(PREROLL_SAMPLES+1),TAIL_BITS=bits_for(TAIL_SAMPLES+1);
    // CLEAR/SETTLE 的等待上限均为 15，不需要第五位。
    reg [3:0] guard;
    reg [PHASE_BITS-1:0] phase;reg [PRE_BITS-1:0] pre_count;reg [TAIL_BITS-1:0] tail_count;
    localparam [PHASE_BITS:0] CLOCK_RATE=CLOCK_HZ;
    localparam [PHASE_BITS:0] SAMPLE_RATE=48000;
    wire [PHASE_BITS:0] phase_sum={1'b0,phase}+SAMPLE_RATE;
    wire soft_tick=phase_sum>=CLOCK_RATE;
    reg [3:0] paused_state;
    assign freeze_media=want_game || active_game;
    assign resource_reset=state==CLEAR;
    assign resource_cancel=state==RETIRE || state==ERROR;
    assign resource_enable=state==LOAD || state==PREROLL || state==PLAY || state==PAUSE || state==BUFFER || state==TAIL || state==RESULT;
    assign engine_reset=rst || state==RETIRE || state==CLEAR || state==STOP || state==SETTLE || state==LOAD;
    assign engine_load=active_game && !engine_reset;
    assign engine_run=active_game && (state==PREROLL || state==PLAY || state==TAIL);
    assign player_mode=(state==PLAY) ? 2'd1 : ((state==STOP || state==RETIRE || state==CLEAR) ? 2'd0 : 2'd2);
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            flags_meta<=0;flags_sync<=0;err_meta<=0;err_sync<=0;err_previous<=0;
            frames_meta<=0;frames_sync<=0;level_meta<=0;level_sync<=0;notes_meta<=0;notes_sync<=0;offset_meta<=0;offset_sync<=0;
            state<=RETIRE;active_game<=0;auto_mode<=1;keys_armed<=0;guard<=0;phase<=0;pre_count<=0;tail_count<=0;
            song_time<=0;song_frames<=0;total_notes<=0;chart_offset<=0;error_code<=0;paused_state<=PLAY;
        end else begin
            flags_meta<={media_quiet_async,resources_ready_async,cancelled_async,audio_eof_async,chart_eof_async};flags_sync<=flags_meta;
            err_meta<=error_async;err_sync<=err_meta;err_previous<=err_sync;frames_meta<=frames_async;frames_sync<=frames_meta;
            level_meta<=fifo_level_async;level_sync<=level_meta;notes_meta<=notes_async;notes_sync<=notes_meta;
            offset_meta<=offset_async;offset_sync<=offset_meta;
            phase<=soft_tick ? phase_sum-CLOCK_RATE : phase_sum[PHASE_BITS-1:0];
            if(!want_game)keys_armed<=0;
            else if(k2_level && k3_level && k4_level)keys_armed<=1;
            // 输出确认脉冲优先校准歌曲时间，包含模式同步退场期间的最后一个采样。
            if(active_game && sample_emitted && (state==PLAY || state==BUFFER || state==PAUSE))song_time<=$signed({1'b0,sample_index});
            if(want_game && keys_armed && k4)auto_mode<=~auto_mode;
            if(state!=RETIRE && state!=CLEAR && (want_game!=active_game ||
                (!want_run && state!=STOP) || (active_game && keys_armed && (k2 || (k4 && state!=STOP)))))begin
                state<=RETIRE;guard<=0;
            // 错误码保持型跨域，连续两次一致后消费，避免多位子原因更新时锁存中间值。
            end else if(active_game && state>=LOAD && state!=ERROR && ((err_sync!=0 && err_sync==err_previous) || queue_overflow))begin
                state<=ERROR;error_code<=queue_overflow ? 4'd10 : err_sync;
            end else case(state)
                RETIRE:if(cancelled && quiet)begin state<=CLEAR;guard<=0;active_game<=want_game;end
                CLEAR:begin
                    song_time<=0;song_frames<=0;total_notes<=0;chart_offset<=0;error_code<=0;pre_count<=0;tail_count<=0;
                    if(guard==4'd15)begin state<=STOP;guard<=0;end else guard<=guard+4'd1;
                end
                STOP:if(want_run)begin state<=SETTLE;guard<=0;end
                SETTLE:if(guard==4'd15)begin state<=LOAD;guard<=0;end else guard<=guard+4'd1;
                LOAD:if(ready && prefetch_ready)begin
                    song_frames<=frames_sync;total_notes<=notes_sync;chart_offset<=offset_sync;
                    if(active_game)begin state<=PREROLL;song_time<=-PREROLL_SAMPLES;pre_count<=0;end
                    else state<=PLAY;
                end
                PREROLL:begin
                    if(keys_armed && k3)begin paused_state<=PREROLL;state<=PAUSE;end
                    else if(soft_tick)begin
                        if(pre_count+1'b1>=PREROLL_SAMPLES)begin song_time<=0;state<=PLAY;end
                        else begin pre_count<=pre_count+1'b1;song_time<=song_time+33'sd1;end
                    end
                end
                PLAY:if(active_game)begin
                    if(song_frames!=0 && emitted_count>=song_frames)begin state<=TAIL;tail_count<=0;end
                    else if(keys_armed && k3)begin state<=PAUSE;paused_state<=PLAY;end
                    else if(sample_missing)state<=BUFFER;
                end
                PAUSE:if(keys_armed && k3)state<=paused_state;
                BUFFER:begin
                    if(song_frames!=0 && emitted_count>=song_frames)begin state<=TAIL;tail_count<=0;end
                    else if(keys_armed && k3)begin state<=PAUSE;paused_state<=BUFFER;end
                    else if(prefetch_ready && (level_sync>=2048 || audio_eof))state<=PLAY;
                end
                TAIL:begin
                    if(keys_armed && k3)begin state<=PAUSE;paused_state<=TAIL;end
                    else if(soft_tick && tail_count<TAIL_SAMPLES)begin tail_count<=tail_count+1'b1;song_time<=song_time+33'sd1;end
                    if(tail_count>=TAIL_SAMPLES && judge_done)state<=RESULT;
                end
                RESULT:begin end
                ERROR:begin end
                default:state<=RETIRE;
            endcase
        end
    end
endmodule
