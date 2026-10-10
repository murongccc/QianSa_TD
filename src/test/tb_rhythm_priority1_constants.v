`timescale 1ns/1ps
// 常数分解逐值比对原版，覆盖合法评分权重之外的原 36 位截断语义。
module tb_rhythm_priority1_constants;
    parameter integer SCORE_DSP=1;
    reg clk=0,rst=1;
    rhythm_judge_core #(.SCORE_DSP(SCORE_DSP)) candidate(
        .clk(clk),.rst_n(!rst),.run(1'b0),.song_time(33'sd0),.chart_offset(32'sd0),.total_notes(16'd0),
        .chart_eof(1'b0),.note_valid(1'b0),.note_data(64'd0),.note_ready(),.event_valid(1'b0),.event_ready(),
        .event_time(33'sd0),.press_mask(4'd0),.release_mask(4'd0),.down_mask(4'd0),.head_valid(),.head_time(),
        .holding_mask(),.view_index(5'd0),.view_valid(),.view_start(),.view_end(),.result_valid(),.result_lane(),
        .result_grade(),.perfect_count(),.good_count(),.bad_count(),.miss_count(),.combo(),.max_combo(),.score(),.done(),.queue_overflow());
    rhythm_judge_core_baseline #(.SCORE_DSP(SCORE_DSP)) reference(
        .clk(clk),.rst_n(!rst),.run(1'b0),.song_time(33'sd0),.chart_offset(32'sd0),.total_notes(16'd0),
        .chart_eof(1'b0),.note_valid(1'b0),.note_data(64'd0),.note_ready(),.event_valid(1'b0),.event_ready(),
        .event_time(33'sd0),.press_mask(4'd0),.release_mask(4'd0),.down_mask(4'd0),.head_valid(),.head_time(),
        .holding_mask(),.view_index(5'd0),.view_valid(),.view_start(),.view_end(),.result_valid(),.result_lane(),
        .result_grade(),.perfect_count(),.good_count(),.bad_count(),.miss_count(),.combo(),.max_combo(),.score(),.done(),.queue_overflow());
    rhythm_game_renderer #(.BLOCK_HUD(1)) renderer(
        .clk(clk),.rst(rst),.enabled(1'b0),.de(1'b0),.vs(1'b0),.song_time(33'sd0),.song_frames(32'd1),
        .state(4'd0),.error_code(4'd0),.auto_mode(1'b0),.score(20'd0),.combo(16'd0),.max_combo(16'd0),
        .perfect_count(16'd0),.good_count(16'd0),.bad_count(16'd0),.miss_count(16'd0),.metadata_valid(1'b0),
        .metadata_data(8'd0),.metadata_address(),.title(192'd0),.difficulty(128'd0),.view_index(),.view_valid(1'b0),
        .view_start(32'd0),.view_end(32'd0),.holding_mask(4'd0),.capture_busy(),.frame_enabled(),.pixel_on(),.pixel_rgb());
    rhythm_game_renderer_baseline #(.BLOCK_HUD(1)) old_renderer(
        .clk(clk),.rst(rst),.enabled(1'b0),.de(1'b0),.vs(1'b0),.song_time(33'sd0),.song_frames(32'd1),
        .state(4'd0),.error_code(4'd0),.auto_mode(1'b0),.score(20'd0),.combo(16'd0),.max_combo(16'd0),
        .perfect_count(16'd0),.good_count(16'd0),.bad_count(16'd0),.miss_count(16'd0),.metadata_valid(1'b0),
        .metadata_data(8'd0),.metadata_address(),.title(192'd0),.difficulty(128'd0),.view_index(),.view_valid(1'b0),
        .view_start(32'd0),.view_end(32'd0),.holding_mask(4'd0),.capture_busy(),.frame_enabled(),.pixel_on(),.pixel_rgb());
    integer n,seed=32'h25613,progress_cases=0;
    reg [32:0] timestamp;
    task check_progress;
        input [32:0] time_bits;
        begin
            renderer.time_snapshot=time_bits;old_renderer.time_snapshot=time_bits;
            renderer.index=0;renderer.work=2;renderer.which_end=0;
            old_renderer.index=0;old_renderer.work=2;old_renderer.which_end=0;
            #2;clk=1;#2;clk=0;
            renderer.work=2;renderer.which_end=1;old_renderer.work=2;old_renderer.which_end=1;
            #2;clk=1;#2;clk=0;#2;
            if(renderer.progress_numerator!==old_renderer.progress_numerator)$fatal(1,"progress factor/share mismatch %h",time_bits);
            progress_cases=progress_cases+1;
        end
    endtask
    initial begin
        #2;clk=1;#2;clk=0;rst=0;
        for(n=0;n<1048576;n=n+1)begin
            candidate.weight=n;reference.weight=n;#1;
            if(candidate.numerator!==reference.numerator)$fatal(1,"score factor mismatch weight=%0d",n);
        end
        check_progress(33'd0);check_progress(33'd262143);check_progress(33'd262144);
        check_progress(33'h0ffffffff);check_progress(33'h100000000);check_progress(33'h1ffffffff);
        for(n=0;n<10000;n=n+1)begin timestamp={$random(seed),$random(seed)};check_progress(timestamp);end
        $display("PASS constants: all 1048576 score weights, %0d full-width progress products",progress_cases);$finish;
    end
    initial begin #2000000;$fatal(1,"constant test timeout");end
endmodule
