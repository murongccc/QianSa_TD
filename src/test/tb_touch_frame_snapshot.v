`timescale 1ns/1ps
module tb_touch_frame_snapshot;
reg src_clk=0,dst_clk=0,src_run=1;
always #10 if(src_run)src_clk=~src_clk;
initial begin #7;forever #20 dst_clk=~dst_clk;end
reg src_rst=1,dst_rst=1,frame_start=0;
reg [39:0] src_packet=0;
reg [39:0] sampled_packet=0;
reg sampled_valid=0;
wire sample_request;
wire [39:0] frame_packet;
integer i,j,cycles;
reg [39:0] frozen;
touch_frame_snapshot dut(.src_clk(src_clk),.src_rst(src_rst),.src_packet(sampled_packet),
    .sample_valid(sampled_valid),.sample_request(sample_request),
    .dst_clk(dst_clk),.dst_rst(dst_rst),.frame_start(frame_start),.frame_packet(frame_packet));
always @(posedge src_clk or posedge src_rst)begin
    if(src_rst)begin sampled_packet<=40'd0;sampled_valid<=1'b0;end
    else begin
        sampled_valid<=sample_request;
        if(sample_request)sampled_packet<=src_packet;
    end
end
function [39:0] pattern;
    input integer n;
    reg [9:0] x;
    reg [8:0] y;
    begin x=n%640;y=(n*7)%480;pattern={n[1:0],x,y,(10'd639-x),(9'd479-y)};end
endfunction
task fail;input [511:0] message;begin $display("FAIL %0s",message);$stop;end endtask
task pulse_frame;
    begin @(negedge dst_clk);frame_start=1;@(negedge dst_clk);frame_start=0;end
endtask
task wait_reply;
    begin
        cycles=0;
        while(dut.waiting_reply && cycles<16)begin @(negedge dst_clk);#1;cycles=cycles+1;end
        if(dut.waiting_reply)fail("snapshot acknowledgement timeout");
        if(frame_packet!==src_packet)fail("snapshot packet mismatch");
    end
endtask
initial begin #1000000;fail("timeout");end
initial begin
    repeat(4)@(negedge dst_clk);src_rst=0;dst_rst=0;
    repeat(5)@(negedge dst_clk);
    for(i=0;i<64;i=i+1)begin
        @(negedge src_clk);src_packet=pattern(i);
        pulse_frame;wait_reply;frozen=frame_packet;
        for(j=0;j<10;j=j+1)begin
            @(negedge src_clk);src_packet=pattern(i*11+j+100);
            @(negedge dst_clk);#1;if(frame_packet!==frozen)fail("visible frame changed without frame request");
        end
    end
    @(negedge src_clk);src_run=0;src_packet=pattern(999);frozen=frame_packet;
    pulse_frame;
    repeat(20)begin pulse_frame;#1;if(frame_packet!==frozen)fail("stopped source tore snapshot");end
    src_run=1;wait_reply;
    @(negedge src_clk);src_run=0;pulse_frame;
    src_rst=1;dst_rst=1;#1;if(frame_packet!==40'd0)fail("reset did not hide markers");
    repeat(3)@(negedge dst_clk);src_run=1;src_rst=0;dst_rst=0;
    @(negedge src_clk);src_packet=pattern(55);pulse_frame;wait_reply;
    $display("PASS frame snapshot: coherent packets, asynchronous clock phase, frame hold, stopped source and reset");
    $finish;
end
endmodule
