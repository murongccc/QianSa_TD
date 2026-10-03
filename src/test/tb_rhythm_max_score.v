`timescale 1ns/1ps
module tb_rhythm_max_score;
    reg clk=0;always #20 clk=~clk;
    reg rst_n=0,note_valid=0,chart_eof=0;
    reg [63:0] note_data=0;
    reg signed [32:0] song_time=0;
    wire note_ready,done,overflow;
    wire [15:0] p,g,b,m,combo,max_combo;wire [19:0] score;
    rhythm_game_engine #(.SHARED_VIEW(1),.BLOCK_QUEUE(1),.SCORE_DSP(1)) dut(.view_capture(1'b0),.input_mode(2'd0),.clk(clk),.rst_n(rst_n),.run(1'b1),.song_time(song_time),.chart_offset(32'sd0),
        .total_notes(16'd65535),.chart_eof(chart_eof),.note_valid(note_valid),.note_data(note_data),.note_ready(note_ready),
        .event_valid(1'b0),.event_ready(),.event_time(33'sd0),.press_mask(4'd0),.release_mask(4'd0),.down_mask(4'd0),
        .head_valid(),.head_time(),.holding_mask(),.view_index(5'd0),.view_valid(),.view_start(),.view_end(),
        .result_valid(),.result_lane(),.result_grade(),.perfect_count(p),.good_count(g),.bad_count(b),.miss_count(m),
        .combo(combo),.max_combo(max_combo),.score(score),.done(done),.queue_overflow(overflow));
    integer i;reg [31:0] start;
    initial begin
        repeat(4)@(negedge clk);rst_n=1;
        for(i=0;i<65535;i=i+1)begin
            start=20000+i*20000;
            @(negedge clk);note_data={32'd0,start};note_valid=1;
            @(posedge clk);while(!note_ready)@(posedge clk);
            @(negedge clk);note_valid=0;song_time={1'b0,start};
            while(p!=i+1)@(negedge clk);
        end
        chart_eof=1;repeat(100)@(negedge clk);
        if(!done || p!=65535 || combo!=65535 || max_combo!=65535 || g || b || m || score!=1000000 || overflow)
            $fatal(1,"maximum count/score failed");
        $display("PASS maximum 65535 notes, ring wrap, combo and exact 1000000 score");$finish;
    end
    // 窄 RAM 每条记录分四拍访问，65535 次串行握手的仿真预算相应增加。
    initial begin #400000000;$fatal(1,"maximum score timeout at %0d, perfect=%0d",i,p);end
endmodule
