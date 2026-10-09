`timescale 1ns/1ps
// 主工程实际使用的请求式映射：中途抢占、完成资格及可见帧冻结。
module tb_touch_stream_snapshot;
reg src_clk=0,dst_clk=0;always #10 src_clk=~src_clk;
initial begin #7;forever #20 dst_clk=~dst_clk;end
reg rst=1,frame_start=0,touch_update=0;
reg [15:0] ax=96,ay=128,bx=16144,by=9440;
reg ad=1,bd=1;
wire request,done,busy;
wire [39:0] source_packet,display_packet;
touch_pixel_mapper #(.ATOMIC_OUTPUT(0)) mapper(
    .clk(src_clk),.rst(rst),.update_valid(request || (touch_update && busy)),
    .a_down(ad),.a_x(ax),.a_y(ay),.b_down(bd),.b_x(bx),.b_y(by),
    .pixel_valid(done),.pixel_packet(source_packet),.busy(busy));
touch_frame_snapshot snapshot(.src_clk(src_clk),.src_rst(rst),.src_packet(source_packet),
    .sample_valid(done),.sample_request(request),.dst_clk(dst_clk),.dst_rst(rst),.frame_start(frame_start),.frame_packet(display_packet));
task pulse_frame;begin @(negedge dst_clk);frame_start=1;@(negedge dst_clk);frame_start=0;end endtask
task wait_frame;
    input [39:0] expected;
    integer n;
    begin
        n=0;while(snapshot.waiting_reply && n<32)begin @(negedge dst_clk);#1;n=n+1;end
        if(snapshot.waiting_reply || display_packet!==expected)begin $display("FAIL stream snapshot expected=%h got=%h",expected,display_packet);$stop;end
    end
endtask
integer i;
reg [39:0] frozen;
initial begin #1000000;$display("FAIL stream timeout");$stop;end
initial begin
    repeat(4)@(negedge dst_clk);rst=0;
    pulse_frame;wait_frame({2'b11,10'd0,9'd0,10'd639,9'd479});frozen=display_packet;
    // 没有帧请求时原始坐标可任意改变，不能更新源结果或显示结果。
    for(i=0;i<30;i=i+1)begin
        @(negedge src_clk);ax=8096;ay=4816;bx=7888;by=4528;touch_update=1;
        @(negedge src_clk);touch_update=0;
        if(display_packet!==frozen || busy)begin $display("FAIL unsolicited mapping/frame tear");$stop;end
    end
    pulse_frame;wait_frame({2'b11,10'd319,9'd241,10'd310,9'd226});
    pulse_frame;
    wait(busy);repeat(5)@(negedge src_clk);
    ax=752;ay=512;ad=0;bd=0;touch_update=1;
    @(negedge src_clk);touch_update=0;
    wait_frame({2'b00,10'd26,9'd20,10'd310,9'd226});
    $display("PASS stream snapshot: qualified partial mapping, restart, frame hold and release");$finish;
end
endmodule
