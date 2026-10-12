`timescale 1ns/1ps
// 四个字的全部高位、写入反压、地址突变和中途复位，禁止泄露半条记录。
module tb_rhythm_packed_queue;
    reg clk=0;always #20 clk=~clk;
    reg rst_n=0,run=0,note_valid=0,chart_eof=0;
    reg [63:0] note_data=0;
    reg signed [32:0] song_time=33'h012340000;
    reg [4:0] view_index=0;
    reg [15:0] total_notes=32;
    wire note_ready,view_valid,done,overflow;
    wire [31:0] view_start,view_end;
    wire [3:0] heads;
    wire [15:0] misses;
    reg vs=0,check_geometry=0;
    wire [4:0] rendered_index;
    wire capture;
    wire geometry_write=renderer.geo_we;
    wire [21:0] geometry_word=renderer.geo_data;
    reg [9:0] expected_head;
    integer geometry_count=0;
    reg [31:0] starts[0:31],ends[0:31];
    integer i;
    rhythm_judge_core #(.BLOCK_QUEUE(1)) dut(
        .clk(clk),.rst_n(rst_n),.run(run),.song_time(song_time),.chart_offset(32'sd0),
        .total_notes(total_notes),.chart_eof(chart_eof),.note_valid(note_valid),.note_data(note_data),.note_ready(note_ready),
        .event_valid(1'b0),.event_ready(),.event_time(33'sd0),.press_mask(4'd0),.release_mask(4'd0),.down_mask(4'd0),
        .head_valid(heads),.head_time(),.holding_mask(),.view_index(view_index),.view_valid(view_valid),.view_start(view_start),.view_end(view_end),
        .result_valid(),.result_lane(),.result_grade(),.perfect_count(),.good_count(),.bad_count(),.miss_count(misses),
        .combo(),.max_combo(),.score(),.done(done),.queue_overflow(overflow));
    rhythm_game_renderer #(.BLOCK_GEOMETRY(1)) renderer(
        .pixel_light(),
        .input_down(4'd0),.input_press(4'd0),
        .clk(clk),.rst(!rst_n),.enabled(1'b1),.de(1'b0),.vs(vs),.song_time(song_time),.song_frames(32'd0),
        .state(4'd6),.error_code(4'd0),.auto_mode(1'b0),.score(20'd0),.combo(16'd0),.max_combo(16'd0),
        .perfect_count(16'd0),.good_count(16'd0),.bad_count(16'd0),.miss_count(16'd0),
        .metadata_valid(1'b0),.metadata_data(8'd0),.metadata_address(),.title(192'd0),.difficulty(128'd0),
        .view_index(rendered_index),.view_valid(view_valid),.view_start(view_start),.view_end(view_end),.holding_mask(4'd0),
        .capture_busy(capture),.frame_enabled(),.pixel_on(),.pixel_rgb());
    // 快照使用真实窄队列，而非组合式视图假数据；首帧特意与最后一条写入重叠。
    always @(negedge clk)if(check_geometry)view_index=rendered_index;
    always @(posedge clk)if(check_geometry && geometry_write)begin
        expected_head=384-(starts[rendered_index]-32'h12340000)/300;
        if(geometry_word!=={1'b1,1'b1,expected_head,10'd64})$fatal(1,"packed snapshot geometry at %0d got %h",rendered_index,geometry_word);
        geometry_count=geometry_count+1;
    end
    task load;
        input [1:0] lane;input [31:0] start;input [23:0] duration;
        begin
            @(negedge clk);note_data={4'd0,1'b0,(duration!=0),lane,duration,start};note_valid=1;
            while(!note_ready)@(negedge clk);
            @(posedge clk);@(negedge clk);note_valid=0;
            if(note_ready || !dut.queue_write_busy)$fatal(1,"missing packed-write backpressure");
        end
    endtask
    task query;
        input [4:0] index;
        begin
            @(negedge clk);view_index=index;repeat(12)@(negedge clk);
            if(!view_valid || view_start!==starts[index] || view_end!==ends[index])
                $fatal(1,"packed record %0d got %h/%h expected %h/%h",index,view_start,view_end,starts[index],ends[index]);
        end
    endtask
    initial begin
        repeat(4)@(negedge clk);rst_n=1;
        for(i=0;i<32;i=i+1)begin
            starts[i]=32'h12340000+5000+i*513;
            ends[i]=starts[i]+24'hf01000+i*257;
            load(i/8,starts[i],ends[i]-starts[i]);
        end
        check_geometry=1;vs=1;
        @(negedge clk);vs=0;repeat(3000)@(negedge clk);
        if(capture || geometry_count!=32)$fatal(1,"packed snapshot did not publish all 32 slots");
        check_geometry=0;
        for(i=0;i<32;i=i+1)query(i[4:0]);
        // 快速跳转时有效记录必须仍属于当前地址，不能拼接上一次读出的半字。
        for(i=0;i<160;i=i+1)begin
            @(negedge clk);view_index=(i*13+7)%32;#1;
            if(view_valid && (view_start!==starts[view_index] || view_end!==ends[view_index]))$fatal(1,"torn record after address jump");
        end
        if(overflow || heads!=15)$fatal(1,"four-lane full queue state");
        @(negedge clk);rst_n=0;repeat(3)@(negedge clk);rst_n=1;total_notes=1;
        load(0,32'h1234abcd,24'habcdef);
        // 打断三拍在途写入，随后复用相同物理 RAM，旧指针和字片均不得重新有效。
        @(negedge clk);rst_n=0;repeat(3)@(negedge clk);rst_n=1;
        repeat(12)@(negedge clk);if(view_valid || heads || dut.queue_write_busy)$fatal(1,"reset leaked partial note");
        starts[8]=32'h1234cdef;ends[8]=starts[8]+24'hfedcba;
        load(1,starts[8],24'hfedcba);query(8);
        song_time={1'b0,starts[8]}+33'sd7201;chart_eof=1;run=1;
        repeat(100)@(negedge clk);
        if(!done || misses!=1 || overflow)$fatal(1,"retire after packed reset");
        $display("PASS packed queue: 32 full-width records, in-flight-write snapshot, backpressure, address tags, partial-write reset and retire");$finish;
    end
    initial begin #2000000;$fatal(1,"packed queue timeout");end
endmodule
