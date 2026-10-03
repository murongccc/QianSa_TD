`timescale 1ns/1ps
module tb_rhythm_song;
    parameter AUTO_MODE=1;
    reg clk=0;always #20 clk=~clk;
    reg rst_n=0;reg signed [32:0] song_time=-96000;
    reg [63:0] notes[0:412];integer position=0,ticks=0;
    wire note_ready,done,overflow;
    wire event_valid,event_ready;wire signed [32:0] event_time;
    wire [3:0] press,down,heads,holding;wire [127:0] times;
    wire [15:0] p,g,b,m,combo,max_combo;wire [19:0] score;
    rhythm_game_engine #(.SHARED_VIEW(1),.BLOCK_QUEUE(1),.SCORE_DSP(1)) dut(.view_capture(1'b0),.input_mode(AUTO_MODE!=0 ? 2'd0 : 2'd1),.clk(clk),.rst_n(rst_n),.run(1'b1),.song_time(song_time),.chart_offset(32'sd0),
        .total_notes(16'd413),.chart_eof(position==413),.note_valid(position<413),.note_data(notes[position<413?position:412]),.note_ready(note_ready),
        .event_valid(1'b0),.event_ready(),.event_time(33'sd0),.press_mask(4'd0),.release_mask(4'd0),.down_mask(4'd0),
        .head_valid(heads),.head_time(times),.holding_mask(holding),.view_index(5'd0),.view_valid(),.view_start(),.view_end(),
        .result_valid(),.result_lane(),.result_grade(),.perfect_count(p),.good_count(g),.bad_count(b),.miss_count(m),
        .combo(combo),.max_combo(max_combo),.score(score),.done(done),.queue_overflow(overflow));
    always @(negedge clk)if(rst_n)begin
        if(note_ready && position<413)position=position+1;
        ticks=ticks+1;if(ticks%16==0)song_time=song_time+33'sd48;
        if(overflow)$fatal(1,"real chart queue overflow at %0d",position);
        if(done)begin
            if(position!=413 || g || b || (AUTO_MODE!=0 && (p!=413 || m || combo!=413 || max_combo!=413 || score!=1000000)) ||
                (AUTO_MODE==0 && (m!=413 || p || combo || max_combo || score)))$fatal(1,"song result P/G/B/M %0d/%0d/%0d/%0d score %0d",p,g,b,m,score);
            $display("PASS real song AUTO=%0d P/G/B/M=%0d/%0d/%0d/%0d combo=%0d score=%0d",AUTO_MODE,p,g,b,m,combo,score);$finish;
        end
    end
    initial begin $readmemh("prj/log/rhythm_stage3_regression/notes.hex",notes);repeat(4)@(negedge clk); #1;rst_n=1;end
    initial begin #100000000;$fatal(1,"song timeout");end
endmodule
