`timescale 1ns/1ps
module tb_rhythm_judge_core;
    reg clk=0;always #20 clk=~clk;
    reg rst_n=0,run=0,chart_eof=0,note_valid=0,event_valid=0;
    reg signed [32:0] song_time=0,event_time=0;
    reg signed [31:0] chart_offset=0;
    reg [15:0] total_notes=1;
    reg [63:0] note_data=0;
    reg [3:0] press_mask=0,release_mask=0,down_mask=0;
    wire note_ready,event_ready,done,overflow,result_valid;
    wire [1:0] result_lane,result_grade;
    wire [15:0] perfect_count,good_count,bad_count,miss_count,combo,max_combo;
    wire [19:0] score;
    wire [3:0] head_valid,holding_mask;
    wire [127:0] head_time;
    reg [4:0] view_index=0;wire view_valid;wire [31:0] view_start,view_end;
    rhythm_game_engine dut(2'd2,clk,rst_n,run,song_time,chart_offset,total_notes,chart_eof,
        note_valid,note_data,note_ready,event_valid,event_ready,event_time,press_mask,release_mask,down_mask,
        head_valid,head_time,holding_mask,view_index,view_valid,view_start,view_end,
        result_valid,result_lane,result_grade,perfect_count,good_count,bad_count,miss_count,combo,max_combo,score,done,overflow);
    task reset;
        begin @(negedge clk);rst_n=0;run=0;note_valid=0;event_valid=0;chart_eof=0;
            press_mask=0;release_mask=0;down_mask=0;chart_offset=0;song_time=0;total_notes=1;
            repeat(3)@(negedge clk);rst_n=1;run=1;end
    endtask
    task load_note;
        input [1:0] track;input [31:0] start;input [23:0] duration;
        begin @(negedge clk);note_data={4'd0,1'b0,(duration!=0),track,duration,start};note_valid=1;
            @(posedge clk);while(!note_ready)@(posedge clk);
            @(negedge clk);note_valid=0;end
    endtask
    task send_event;
        input signed [32:0] timestamp;input [3:0] press;input [3:0] release_bits;input [3:0] down;
        begin @(negedge clk);event_time=timestamp;press_mask=press;release_mask=release_bits;down_mask=down;event_valid=1;
            @(posedge clk);while(!event_ready)@(posedge clk);
            @(negedge clk);event_valid=0;repeat(6)@(negedge clk);end
    endtask
    task check;
        input [1:0] grade;input [19:0] expected_score;
        begin repeat(90)@(negedge clk);
            if(!done || score!=expected_score || perfect_count!=(grade==3) || good_count!=(grade==2) ||
                bad_count!=(grade==1) || miss_count!=(grade==0) || overflow)
                $fatal(1,"single result grade=%0d score=%0d P/G/B/M=%0d/%0d/%0d/%0d",grade,score,perfect_count,good_count,bad_count,miss_count);
        end
    endtask
    task tap_case;
        input integer offset;input [1:0] grade;
        reg [19:0] expected_score;
        begin reset;load_note(0,20000,0);chart_eof=1;song_time=20000+offset;
            send_event(20000+offset,1,0,1);
            if(grade==0)begin song_time=30000;end
            expected_score=grade==3?1000000:(grade==2?700000:(grade==1?300000:0));check(grade,expected_score);
        end
    endtask
    integer n;
    initial begin
        tap_case(-2400,3);tap_case(2400,3);tap_case(-2401,2);tap_case(4800,2);
        tap_case(-4801,1);tap_case(7200,1);tap_case(-7201,0);tap_case(7201,0);
        reset;load_note(0,20000,10000);chart_eof=1;song_time=23000;
        send_event(23000,1,0,1);song_time=27600;send_event(27600,0,1,0);check(2,700000);
        reset;load_note(0,20000,10000);chart_eof=1;song_time=20000;
        send_event(20000,1,0,1);song_time=27599;send_event(27599,0,1,0);check(0,0);
        reset;load_note(0,20000,10000);chart_eof=1;song_time=20000;
        send_event(20000,1,0,1);run=0;down_mask=0;song_time=21000;
        repeat(40)@(negedge clk);if(miss_count!=0)$fatal(1,"paused hold changed");run=1;check(0,0);
        reset;load_note(0,20000,10000);chart_eof=1;song_time=20000;
        send_event(20000,1,0,1);repeat(40)@(negedge clk);
        if(perfect_count!=0 || score!=0)$fatal(1,"Hold counted at head");
        song_time=30000;check(3,1000000);
        reset;load_note(0,20000,10000);chart_eof=1;song_time=25000;
        send_event(25000,1,0,1);song_time=30000;check(1,300000);
        reset;load_note(0,20000,1);chart_eof=1;song_time=20000;
        send_event(20000,1,0,1);song_time=20001;check(3,1000000);
        // 空按忽略；三个不同等级的归一化结果必须向下取整。
        reset;total_notes=3;load_note(0,20000,0);load_note(1,30000,0);load_note(2,40000,0);chart_eof=1;
        send_event(0,8,0,8);if((perfect_count | good_count | bad_count | miss_count)!=0)$fatal(1,"empty press counted");
        song_time=20000;send_event(20000,1,0,1);
        song_time=33000;send_event(33000,2,0,2);
        song_time=45000;send_event(45000,4,0,4);repeat(100)@(negedge clk);
        if(!done || perfect_count!=1 || good_count!=1 || bad_count!=1 || miss_count || score!=666666 || combo || max_combo!=2)
            $fatal(1,"mixed score/combo");
        // 和弦接收之后时间跳到窗外，四轨仍应使用接收时的 2400 帧偏差。
        reset;total_notes=4;for(n=0;n<4;n=n+1)load_note(n[1:0],20000,0);chart_eof=1;song_time=22400;
        @(negedge clk);event_time=22400;press_mask=15;down_mask=15;event_valid=1;
        @(posedge clk);while(!event_ready)@(posedge clk);@(negedge clk);event_valid=0;song_time=100000;
        repeat(100)@(negedge clk);
        if(!done || perfect_count!=4 || combo!=4 || max_combo!=4 || score!=1000000)$fatal(1,"chord timestamp");
        // 带偏移、负预滚、视图及暂停输入反压。
        reset;chart_offset=4800;song_time=-96000;note_data=64'd20000;note_valid=1;
        repeat(4)@(negedge clk);if(note_ready || head_valid!=0)$fatal(1,"early activation");
        song_time=-71200;@(posedge clk);while(!note_ready)@(posedge clk);@(negedge clk);note_valid=0;
        if(!view_valid || view_start!=24800 || view_end!=24800)$fatal(1,"offset/view");
        chart_eof=1;run=0;event_valid=1;event_time=24800;press_mask=1;down_mask=1;
        repeat(8)@(negedge clk);if(event_ready || perfect_count!=0)$fatal(1,"pause event accepted");
        song_time=24800;run=1;@(posedge clk);while(!event_ready)@(posedge clk);@(negedge clk);event_valid=0;check(3,1000000);
        // 八槽满队列对第九个到期音符反压并显式报告容量错误。
        reset;total_notes=9;for(n=0;n<8;n=n+1)load_note(0,20000+n*1000,0);
        @(negedge clk);note_data=64'd28000;note_valid=1;repeat(4)@(negedge clk);
        if(note_ready || !overflow)$fatal(1,"queue capacity");
        reset;repeat(10)@(negedge clk);if(head_valid || overflow || score || combo)$fatal(1,"reset stale state");
        $display("PASS judge boundaries, hold, pause, chord, offset, capacity/reset");$finish;
    end
    initial begin #10000000;$fatal(1,"timeout");end
endmodule
