`timescale 1ns/1ps
// 真实窄队列/DSP 引擎、双时钟触摸桥和会话控制闭环；音频采样确认由测试驱动。
module tb_rhythm_end_retirement;
parameter integer PHASE=3,HALF=20,LAST_KIND=0,END_IN_TAIL=0,LATE_EOF=0;
parameter integer TAIL_SAMPLES=64;
parameter integer BASELINE_ENGINE=0,KEEP_INPUT_AFTER_DONE=0;
reg sc=0,dc=0,rst=1;
always #10 sc=~sc;
initial begin #(PHASE);forever #(HALF) dc=~dc;end
reg capture=0,nv=0,eof=1,sv=0,k2=1;
reg [63:0] note=0;
reg [3:0] sp=0,sr=0,sd=0;
reg [15:0] resource_notes=1;
reg emitted=0;
reg [31:0] sample_index=0,emitted_count=0;
wire active,auto_mode,clear,engine_reset,engine_run,engine_load;
wire [3:0] state,error;
wire signed [32:0] song_time;
wire signed [31:0] offset;
wire [31:0] song_frames;
wire [15:0] total_notes;
wire src_enable,ev,er,overflow,fault,nr,done,qo;
wire signed [32:0] et;
wire [3:0] press,release_bits,down,holding;
wire [15:0] perfect,good,bad,miss,combo,max_combo;
wire [19:0] score;
wire session_eof;
integer scenario=0,checks=0,i;
reg [19:0] saved_score;
reg [15:0] saved_perfect,saved_miss,saved_combo;
reg [31:0] note_start;

rhythm_session_controller #(.CLOCK_HZ(480000),.DEBOUNCE_MS(1),.PREROLL_SAMPLES(8),.TAIL_SAMPLES(TAIL_SAMPLES)) session(
    .clk(dc),.rst(rst),.game_switch(1'b1),.run_switch(1'b1),
    .restart_key_n(k2),.pause_key_n(1'b1),.mode_key_n(1'b1),
    .media_quiet_async(1'b1),.resources_ready_async(1'b1),.cancelled_async(1'b1),
    .audio_eof_async(1'b0),.chart_eof_async(eof),.error_async(4'd0),
    .frames_async(32'd30000),.fifo_level_async(32'd4096),.notes_async(resource_notes),.offset_async(32'sd0),
    .sample_emitted(emitted),.sample_missing(1'b0),.prefetch_ready(1'b1),
    .sample_index(sample_index),.emitted_count(emitted_count),.judge_done(done),.queue_overflow(qo || fault),
    .freeze_media(),.active_game(active),.auto_mode(auto_mode),.resource_reset(clear),.resource_enable(),.resource_cancel(),
    .engine_reset(engine_reset),.engine_run(engine_run),.engine_load(engine_load),.player_mode(),
    .song_time(song_time),.song_frames(song_frames),.total_notes(total_notes),.chart_offset(offset),
    .chart_eof(session_eof),.state(state),.error_code(error));

// 与板级连接一致；KEEP_INPUT_AFTER_DONE 仅用于验证旧连接确实不能通过回归。
touch_game_event_bridge bridge(
    .src_clk(sc),.src_rst(rst),.dst_clk(dc),.dst_rst(rst),
    .enable(engine_run && !engine_reset && !auto_mode && (KEEP_INPUT_AFTER_DONE || !done)),.src_enable(src_enable),
    .src_valid(sv),.src_press(sp),.src_release(sr),.src_down(sd),.game_time(song_time),
    .event_valid(ev),.event_ready(er),.event_time(et),.press_mask(press),.release_mask(release_bits),.down_mask(down),
    .overflow(overflow),.fault(fault));

// 同一测试也运行修改前的引擎，证明在途事件排空检查能检出原缺陷。
`define END_ENGINE_PORTS \
    .clk(dc),.rst_n(!engine_reset),.run(engine_run && !capture),.view_capture(capture),.input_mode(2'd2), \
    .song_time(song_time),.chart_offset(offset),.total_notes(total_notes),.chart_eof(session_eof), \
    .note_valid(nv && engine_load && !capture),.note_data(note),.note_ready(nr), \
    .event_valid(ev),.event_ready(er),.event_time(et),.press_mask(press),.release_mask(release_bits),.down_mask(down), \
    .head_valid(),.head_time(),.holding_mask(holding),.view_index(5'd0),.view_valid(),.view_start(),.view_end(), \
    .result_valid(),.result_lane(),.result_grade(),.perfect_count(perfect),.good_count(good),.bad_count(bad),.miss_count(miss), \
    .combo(combo),.max_combo(max_combo),.score(score),.done(done),.queue_overflow(qo)
generate if(BASELINE_ENGINE)begin: old_engine
    baseline_rhythm_game_engine #(.SHARED_VIEW(1),.BLOCK_QUEUE(1),.SCORE_DSP(1)) engine(`END_ENGINE_PORTS);
end else begin: fixed_engine
    rhythm_game_engine #(.SHARED_VIEW(1),.BLOCK_QUEUE(1),.SCORE_DSP(1)) engine(`END_ENGINE_PORTS);
end endgenerate
`undef END_ENGINE_PORTS

always @(posedge dc)if(clear)begin sample_index<=0;emitted_count<=0;end
always @(negedge dc)if(!rst && scenario==1 && state==11)
    $fatal(1,"terminal input changed normal completion to ERROR %0d",error);

task wait_state;
    input [3:0] expected;
    integer n;
    begin
        n=0;
        while(state!=expected && n<4000)begin @(negedge dc);n=n+1;end
        if(state!=expected)$fatal(1,"state timeout expected=%0d actual=%0d",expected,state);
    end
endtask
task start_session;
    input [15:0] count;
    begin
        @(negedge dc);scenario=0;rst=1;capture=0;nv=0;sv=0;sp=0;sr=0;sd=0;k2=1;
        emitted=0;sample_index=0;emitted_count=0;resource_notes=count;eof=1;
        repeat(5)@(negedge dc);rst=0;wait_state(6);
        wait(src_enable);repeat(20)@(negedge dc);
    end
endtask
task emit_sample;
    input [31:0] index;
    begin
        @(negedge dc);sample_index=index;emitted_count=index+32'd1;emitted=1;
        @(negedge dc);emitted=0;repeat(3)@(negedge dc);
    end
endtask
task load_note;
    input [23:0] duration;
    integer n;
    begin
        @(negedge dc);note={4'd0,1'b0,(duration!=0),2'd0,duration,note_start};nv=1;n=0;
        while(!nr && n<100)begin @(negedge dc);n=n+1;end
        if(!nr)$fatal(1,"note load stalled");
        @(posedge dc);@(negedge dc);nv=0;repeat(30)@(negedge dc);
    end
endtask
task send;
    input [3:0] p,r,d;
    begin
        @(negedge sc);sp=p;sr=r;sd=d;sv=src_enable;
        @(negedge sc);sv=0;
    end
endtask
task stable_result;
    begin
        if(score!==saved_score || perfect!==saved_perfect || miss!==saved_miss || combo!==saved_combo || good || bad)
            $fatal(1,"post-completion input changed score/judgment counters");
        if(overflow || fault || qo || error)$fatal(1,"unexpected completion fault");
        checks=checks+1;
    end
endtask

initial begin
    start_session(1);scenario=1;
    note_start=END_IN_TAIL ? 32'd29900 : 32'd1000;
    load_note(LAST_KIND==1 ? 24'd4800 : 24'd0);
    if(END_IN_TAIL)begin
        if(LAST_KIND==1)$fatal(1,"tail case requires a Tap");
        emit_sample(32'd29999);wait_state(9);
    end else emit_sample(note_start);
    if(LAST_KIND==2)begin
        if(!END_IN_TAIL)emit_sample(note_start+32'd7201);
    end else begin
        send(1,0,1);
        if(LAST_KIND==1)begin wait(holding[0]);emit_sample(note_start+32'd4800);end
    end
    wait(perfect+miss==1);
    // 帧快照阻塞消费者；命中场景利用分数 DSP 计算窗口留下真实在途事件。
    @(negedge dc);capture=1;
    if(LATE_EOF)eof=0;
    send(0,1,0);repeat(10)@(negedge dc);send(2,0,2);
    if(LATE_EOF)begin repeat(70)@(negedge dc);eof=1;end
    wait(done);@(negedge dc);
    if(!er)$fatal(1,"terminal drain blocked during capture");
    if(LAST_KIND==2)begin
        if(miss!=1 || perfect || score || combo)$fatal(1,"final Miss result wrong");
    end else if(perfect!=1 || miss || score!=20'd1000000 || combo!=1)$fatal(1,"final hit result wrong");
    saved_score=score;saved_perfect=perfect;saved_miss=miss;saved_combo=combo;
    repeat(40)@(negedge dc);
    if(src_enable)$fatal(1,"touch source did not retire");
    if(ev || down || bridge.req || bridge.count!=0)$fatal(1,"in-flight input did not flush");
    stable_result;
    // 即使快照持续阻塞，音乐余段、TAIL、RESULT 中的连续触摸都不能再入队。
    for(i=0;i<12;i=i+1)begin
        send(1,0,1);repeat(4)@(negedge dc);send(0,1,0);repeat(4)@(negedge dc);stable_result;
    end
    if(!END_IN_TAIL)begin
        if(state!=6)$fatal(1,"audio tail was truncated by judge_done");
        emit_sample(32'd29999);
    end
    wait_state(10);
    for(i=0;i<6;i=i+1)begin send(4,0,4);send(0,4,0);repeat(10)@(negedge dc);stable_result;end
    // 结果页重开仍可重新启用输入，不能消费上一局的按下状态。
    scenario=0;@(negedge dc);capture=0;k2=0;
    wait_state(0);wait_state(6);k2=1;wait(src_enable);repeat(30)@(negedge dc);
    if(done || ev || down || overflow || fault || qo || perfect || miss || score)
        $fatal(1,"restart leaked completed-game state");

    // 正常游戏期间消费者长期反压：第五项事件必须触发真实触摸溢出和 EA。
    start_session(1);note_start=1000;load_note(0);capture=1;
    for(i=0;i<5;i=i+1)begin send(i[0] ? 4'd0 : 4'd1,i[0] ? 4'd1 : 4'd0,i[0] ? 4'd0 : 4'd1);repeat(20)@(negedge dc);end
    wait_state(11);
    if(error!=10 || done || qo)$fatal(1,"live touch overflow was not preserved");
    repeat(80)@(negedge dc);
    if(state!=11 || error!=10)$fatal(1,"live fault cleared during input retirement");

    // 正常游戏的音符队列真溢出也必须保持原有 EA 检测。
    start_session(9);note_start=1000;
    for(i=0;i<8;i=i+1)load_note(0);
    @(negedge dc);note={32'd0,note_start};nv=1;wait_state(11);nv=0;
    if(error!=10 || !qo || done || fault)$fatal(1,"live note queue overflow was not preserved");
    $display("PASS end retirement kind=%0d tail=%0d late_eof=%0d phase=%0d half=%0d: %0d stable score checks, in-flight/capture flush, RESULT/restart, live touch/note overflow EA",LAST_KIND,END_IN_TAIL,LATE_EOF,PHASE,HALF,checks);
    $finish;
end
initial begin #10000000;$fatal(1,"end regression timeout scenario=%0d state=%0d",scenario,state);end
endmodule
