`timescale 1ns/1ps

// 对照迁移前模块，覆盖五槽基线、非法槽号、缺数、多数、复位及计数饱和。
module tb_frame_monitor_ram_equivalence;
reg clk=0, rst=1, display_valid=0, vs=0, req=0, empty=0, valid=0;
reg [2:0] slot=0;
reg [31:0] data=0;
wire [15:0] under_new, under_old, mismatch_new, mismatch_old;
wire under_sticky_new, under_sticky_old, mismatch_sticky_new, mismatch_sticky_old;
integer frame_index, word_index, words;
reg [31:0] random_state=32'h371a902d;
always #5 clk=~clk;

frame_read_monitor #(.FRAME_PIXELS(8)) dut(
    .clk(clk),.rst(rst),.display_valid_async(display_valid),.display_slot_async(slot),.vs(vs),
    .fifo_read_req(req),.fifo_empty(empty),.fifo_valid(valid),.fifo_data(data),
    .underflow_count(under_new),.underflow_sticky(under_sticky_new),
    .mismatch_count(mismatch_new),.mismatch_sticky(mismatch_sticky_new));
baseline_frame_read_monitor #(.FRAME_PIXELS(8)) reference_monitor(
    .clk(clk),.rst(rst),.display_valid_async(display_valid),.display_slot_async(slot),.vs(vs),
    .fifo_read_req(req),.fifo_empty(empty),.fifo_valid(valid),.fifo_data(data),
    .underflow_count(under_old),.underflow_sticky(under_sticky_old),
    .mismatch_count(mismatch_old),.mismatch_sticky(mismatch_sticky_old));

always @(posedge clk) begin
    #1;
    if ({under_new,under_sticky_new,mismatch_new,mismatch_sticky_new} !==
        {under_old,under_sticky_old,mismatch_old,mismatch_sticky_old})
        $fatal(1,"monitor mismatch frame=%0d new=%0d/%0d old=%0d/%0d",frame_index,
            under_new,mismatch_new,under_old,mismatch_old);
end

task boundary;
begin
    @(negedge clk);vs=1;valid=0;
    @(negedge clk);vs=0;
end
endtask

initial begin
    repeat(3) @(negedge clk);rst=0;display_valid=1;
    repeat(4) @(negedge clk);boundary;
    for(frame_index=0;frame_index<400;frame_index=frame_index+1) begin
        // 每槽连续四帧：建立基线、相同帧、单像素变化、再次相同帧。
        words=8;
        if(frame_index>=80 && frame_index%11==0) words=7;
        if(frame_index>=80 && frame_index%13==0) words=9;
        for(word_index=0;word_index<words;word_index=word_index+1) begin
            @(negedge clk);
            random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
            data=32'h01020304 ^ (word_index*32'h00111111) ^
                 (((frame_index/4)%8)*32'h10203040);
            if(frame_index%4==2 && word_index==3) data=data^32'h10000001;
            valid=1;req=random_state[0];empty=random_state[1];
            @(negedge clk);valid=0;
        end
        slot=((frame_index+1)/4)%8;
        repeat(3) @(negedge clk);
        boundary;
        if(frame_index==180) begin
            rst=1;repeat(2) @(negedge clk);rst=0;
            repeat(4) @(negedge clk);boundary;
        end
    end
    @(negedge clk);req=1;empty=1;
    repeat(65540) @(negedge clk);
    if(under_new!==16'hffff || mismatch_new==0)
        $fatal(1,"test did not cover saturation and signature errors");
    $display("PASS RAM baseline equivalence: 400 frames, five slots, invalid slots, reset, pixel faults, saturation");
    $finish;
end
initial begin #2000000;$fatal(1,"timeout");end
endmodule
