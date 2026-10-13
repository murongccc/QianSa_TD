`timescale 1ns/1ps
module tb_touch_rhythm_integration;
reg sc=0,dc=0;always #10 sc=~sc;initial begin #3;forever #20 dc=~dc;end
reg rst=1,enable=1,capture=0,gate=1,update=0,ad=0,bd=0;
reg [3:0] ai=1,bi=2;reg [15:0] ax=1500,ay=8000,bx=3500,by=8000;
reg signed [32:0] song_time=0;
reg [1:0] mode=2;
wire se,lv,ev,er,armed,overflow,fault;wire [3:0] lp,lr,ld,p,r,d,holding;
wire signed [32:0] et;
touch_lane_input lanes(sc,rst,se,update,ai,ad,ax,ay,bi,bd,bx,by,lv,lp,lr,ld,armed,4'd0,1'b0,16'd0,16'd0,ad|bd);
touch_game_event_bridge bridge(sc,rst,dc,rst,enable && mode==2,se,lv,lp,lr,ld,song_time,ev,er && gate,et,p,r,d,overflow,fault);
reg nv=0,eof=0;reg [63:0] note=0;reg [15:0] total=1;
wire nr,done,qo;wire [15:0] perfect,miss;wire [19:0] score;
rhythm_game_engine #(.BLOCK_QUEUE(1),.SHARED_VIEW(1),.SCORE_DSP(1)) engine(
    .clk(dc),.rst_n(!rst),.run(enable && !capture),.view_capture(capture),.input_mode(mode),
    .song_time(song_time),.chart_offset(32'sd0),.total_notes(total),.chart_eof(eof),
    .note_valid(nv),.note_data(note),.note_ready(nr),
    .event_valid(ev && gate),.event_ready(er),.event_time(et),.press_mask(p),.release_mask(r),.down_mask(d),
    .head_valid(),.head_time(),.holding_mask(holding),.view_index(5'd0),.view_valid(),.view_start(),.view_end(),
    .result_valid(),.result_lane(),.result_grade(),.perfect_count(perfect),.good_count(),.bad_count(),.miss_count(miss),
    .combo(),.max_combo(),.score(score),.done(done),.queue_overflow(qo));
task reset;input [15:0] n;begin
    @(negedge dc);rst=1;ad=0;bd=0;update=0;nv=0;eof=0;total=n;song_time=0;capture=0;gate=1;
    repeat(5)@(negedge dc);rst=0;wait(armed);repeat(20)@(negedge dc);
end endtask
task load;input [1:0] lane;input [23:0] duration;begin
    @(negedge dc);note={4'd0,1'b0,(duration!=0),lane,duration,32'd20000};nv=1;
    @(posedge dc);while(!nr)@(posedge dc);@(negedge dc);nv=0;repeat(20)@(negedge dc);
end endtask
task report;input a,b;begin
    @(negedge sc);ad=a;bd=b;update=1;@(negedge sc);update=0;
end endtask
task settle;begin repeat(100)@(negedge dc);end endtask
task check;input [15:0] ep,em;begin
    settle;repeat(100)@(negedge dc);if(perfect!==ep || miss!==em || overflow || qo || !done)$fatal(1,"chain P/M=%d/%d done %b",perfect,miss,done);
end endtask
initial begin
    reset(1);load(0,0);eof=1;song_time=20000;
    capture=1;report(1,0);repeat(15)@(negedge dc);report(0,0);
    repeat(40)@(negedge dc);if(perfect || !ev)$fatal(1,"capture swallowed/accepted tap");
    capture=0;check(1,0);
    reset(2);load(0,0);load(1,0);eof=1;song_time=20000;report(1,1);check(2,0);
    reset(1);load(0,10000);eof=1;song_time=20000;report(1,0);settle;
    if(holding!==1 || perfect || miss)$fatal(1,"hold head");
    song_time=28000;gate=0;report(0,0);wait(ev);
    repeat(80)@(negedge dc);
    if(holding!==1 || miss || d!==1)$fatal(1,"pending release caused early Hold failure");
    gate=1;check(1,0);
    reset(1);load(0,10000);eof=1;song_time=20000;report(1,0);settle;
    song_time=21000;report(0,0);check(0,1);
    reset(1);load(0,10000);eof=1;song_time=20000;report(1,0);settle;
    enable=0;repeat(20)@(negedge dc);enable=1;repeat(30)@(negedge dc);
    if(armed || ld || ev)$fatal(1,"resume held contact armed");
    report(0,0);wait(armed);report(1,0);settle;
    reset(1);mode=0;load(0,0);eof=1;song_time=20000;report(1,1);check(1,0);
    if(se || ev || ld)$fatal(1,"AUTO accepted touch");
    $display("PASS real optimized engine Tap, double press, Hold success/early release, capture, ordered down, resume, AUTO");$finish;
end
initial begin #2000000;$fatal(1,"timeout");end
endmodule
