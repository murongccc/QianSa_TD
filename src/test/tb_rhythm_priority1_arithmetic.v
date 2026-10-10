`timescale 1ns/1ps
// 与修改前模块直接比较：完整 33 位时间范围限幅、16 位除数与最大评分权重。
module tb_rhythm_priority1_arithmetic;
    reg clk=0,rst=1;
    reg [31:0] view_value=0;
    reg renderer_done=0,score_done=0;
    rhythm_game_renderer #(.BLOCK_HUD(1)) candidate(
        .clk(clk),.rst(rst),.enabled(1'b0),.de(1'b0),.vs(1'b0),.song_time(33'sd0),.song_frames(32'd1),
        .state(4'd0),.error_code(4'd0),.auto_mode(1'b0),.score(20'd0),.combo(16'd0),.max_combo(16'd0),
        .perfect_count(16'd0),.good_count(16'd0),.bad_count(16'd0),.miss_count(16'd0),
        .metadata_valid(1'b0),.metadata_data(8'd0),.metadata_address(),.title(192'd0),.difficulty(128'd0),
        .view_index(),.view_valid(1'b0),.view_start(view_value),.view_end(view_value),.holding_mask(4'd0),
        .capture_busy(),.frame_enabled(),.pixel_on(),.pixel_rgb());
    rhythm_game_renderer_baseline #(.BLOCK_HUD(1)) reference(
        .clk(clk),.rst(rst),.enabled(1'b0),.de(1'b0),.vs(1'b0),.song_time(33'sd0),.song_frames(32'd1),
        .state(4'd0),.error_code(4'd0),.auto_mode(1'b0),.score(20'd0),.combo(16'd0),.max_combo(16'd0),
        .perfect_count(16'd0),.good_count(16'd0),.bad_count(16'd0),.miss_count(16'd0),
        .metadata_valid(1'b0),.metadata_data(8'd0),.metadata_address(),.title(192'd0),.difficulty(128'd0),
        .view_index(),.view_valid(1'b0),.view_start(view_value),.view_end(view_value),.holding_mask(4'd0),
        .capture_busy(),.frame_enabled(),.pixel_on(),.pixel_rgb());
    integer n,seed=32'h127acd,renderer_cases=0;
    reg signed [32:0] random_time;
    reg [31:0] random_view;
    task check_renderer;
        input signed [32:0] timestamp;
        input [31:0] position;
        begin
            view_value=position;
            candidate.time_snapshot=timestamp;reference.time_snapshot=timestamp;
            candidate.which_end=0;reference.which_end=0;
            candidate.work=2;reference.work=2;
            #2;clk=1;#2;
            if(candidate.dividend!==reference.dividend || candidate.negative!==reference.negative)
                $fatal(1,"time clamp mismatch time=%0d position=%h",timestamp,position);
            clk=0;#2;renderer_cases=renderer_cases+1;
        end
    endtask
    initial begin
        #2;clk=1;#2;clk=0;rst=0;
        check_renderer(-33'sd4294967296,32'hffffffff);
        check_renderer(33'sd4294967295,32'd0);
        check_renderer(33'sd0,32'hffffffff);
        check_renderer(-33'sd96000,32'd0);
        for(n=-2;n<=2;n=n+1)begin
            check_renderer(33'sd1000000,1000000+96000+n);
            check_renderer(33'sd1000000,1000000-96000+n);
            check_renderer(33'sd1000000,1000000+131072+n);
            check_renderer(33'sd1000000,1000000-131072+n);
        end
        for(n=0;n<10000;n=n+1)begin
            random_time={$random(seed),$random(seed)};random_view=$random(seed);
            check_renderer(random_time,random_view);
        end
        renderer_done=1;
    end

    reg sclk=0,srst_n=0;
    always #5 sclk=~sclk;
    reg [15:0] total_notes=1;
    wire [19:0] candidate_score,reference_score;
    rhythm_judge_core #(.SCORE_DSP(1)) score_candidate(
        .clk(sclk),.rst_n(srst_n),.run(1'b0),.song_time(33'sd0),.chart_offset(32'sd0),
        .total_notes(total_notes),.chart_eof(1'b0),.note_valid(1'b0),.note_data(64'd0),.note_ready(),
        .event_valid(1'b0),.event_ready(),.event_time(33'sd0),.press_mask(4'd0),.release_mask(4'd0),.down_mask(4'd0),
        .head_valid(),.head_time(),.holding_mask(),.view_index(5'd0),.view_valid(),.view_start(),.view_end(),
        .result_valid(),.result_lane(),.result_grade(),.perfect_count(),.good_count(),.bad_count(),.miss_count(),
        .combo(),.max_combo(),.score(candidate_score),.done(),.queue_overflow());
    rhythm_judge_core_baseline #(.SCORE_DSP(1)) score_reference(
        .clk(sclk),.rst_n(srst_n),.run(1'b0),.song_time(33'sd0),.chart_offset(32'sd0),
        .total_notes(total_notes),.chart_eof(1'b0),.note_valid(1'b0),.note_data(64'd0),.note_ready(),
        .event_valid(1'b0),.event_ready(),.event_time(33'sd0),.press_mask(4'd0),.release_mask(4'd0),.down_mask(4'd0),
        .head_valid(),.head_time(),.holding_mask(),.view_index(5'd0),.view_valid(),.view_start(),.view_end(),
        .result_valid(),.result_lane(),.result_grade(),.perfect_count(),.good_count(),.bad_count(),.miss_count(),
        .combo(),.max_combo(),.score(reference_score),.done(),.queue_overflow());
    integer s,j,score_seed=32'h183761,score_cases=0;
    reg [19:0] test_weight;
    reg [63:0] expected_numerator;
    task check_score;
        input [15:0] divisor;
        input [19:0] value;
        begin
            @(negedge sclk);srst_n=0;total_notes=divisor;
            @(negedge sclk);srst_n=1;
            score_candidate.weight=value;score_reference.weight=value;
            expected_numerator=value;expected_numerator=expected_numerator*64'd100000;
            for(j=0;j<40;j=j+1)begin
                @(negedge sclk);
                if(candidate_score!==reference_score || score_candidate.dividing!==score_reference.dividing ||
                   {1'b0,score_candidate.remainder}!==score_reference.remainder)
                    $fatal(1,"score cycle mismatch divisor=%0d weight=%0d",divisor,value);
                if(score_candidate.dividing && score_candidate.remainder>=divisor)
                    $fatal(1,"score remainder invariant");
            end
            if(candidate_score!==(expected_numerator/divisor))$fatal(1,"score reference arithmetic");
            score_cases=score_cases+1;
        end
    endtask
    initial begin
        check_score(16'd65535,20'd655350);
        check_score(16'd65535,20'd458745);
        check_score(16'd65535,20'd196605);
        check_score(16'd1,20'd10);check_score(16'd1,20'd0);
        for(s=0;s<1000;s=s+1)begin
            total_notes=($random(score_seed)&32'h7fffffff)%65535+1;
            test_weight=($random(score_seed)&32'h7fffffff)%(total_notes*10+1);
            check_score(total_notes,test_weight);
        end
        score_done=1;
    end
    initial begin
        wait(renderer_done && score_done);
        $display("PASS priority1 arithmetic: %0d full-range clamps, %0d exact score divisions",renderer_cases,score_cases);
        $finish;
    end
    initial begin #2000000;$fatal(1,"priority1 arithmetic timeout");end
endmodule
