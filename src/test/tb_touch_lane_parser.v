`timescale 1ns/1ps
// 真实解析器原子提交后接入绑定层，验证记录压缩/编号替换不会沿用旧绑定。
module tb_touch_lane_parser;
reg clk=0;always #10 clk=~clk;
reg rst=1,bv=0;reg [7:0] data=0;
wire update,ad,bd,valid,armed;wire [3:0] ai,bi,p,r,d;
wire [15:0] ax,ay,bx,by;
ch9350_touch_parser parser(.clk(clk),.rst(rst),.byte_valid(bv),.byte_data(data),.byte_error(1'b0),
    .ack_request(),.update_valid(update),.a_id(ai),.a_down(ad),.a_x(ax),.a_y(ay),
    .b_id(bi),.b_down(bd),.b_x(bx),.b_y(by),.press_mask(),.release_mask(),.frame_seq(),
    .good_count(),.checksum_error_count(),.format_error_count(),.sequence_gap_count(),.timeout_count(),.uart_error_count());
touch_lane_input lane(clk,rst,1'b1,update,ai,ad,ax,ay,bi,bd,bx,by,valid,p,r,d,armed);
reg [7:0] frame[0:60];integer seq=0,events=0;
reg [11:0] last_event=0;
always @(negedge clk)if(valid)begin events=events+1;last_event={p,r,d};end
task byte;input [7:0] v;begin
    @(negedge clk);data=v;bv=1;@(negedge clk);bv=0;
end endtask
task report;
input [7:0] s0,s1;input [15:0] x0,x1;input [1:0] count;input bad;
input [3:0] ep,er,ed;
integer i,before_events;reg [7:0] sum;
begin
    before_events=events;
    for(i=0;i<61;i=i+1)frame[i]=0;
    frame[0]=8'h57;frame[1]=8'hab;frame[2]=8'h88;frame[3]=57;frame[4]=8'h40;frame[5]=8'h0d;
    frame[6]=s0;frame[7]=x0[7:0];frame[8]=x0[15:8];frame[9]=8'h40;frame[10]=8'h1f;
    frame[11]=s1;frame[12]=x1[7:0];frame[13]=x1[15:8];
    if(count==2)begin frame[14]=8'h40;frame[15]=8'h1f;end
    frame[58]={6'd0,count};frame[59]=seq;seq=seq+1;
    sum=0;for(i=5;i<60;i=i+1)sum=sum+frame[i];frame[60]=bad ? sum^8'h01 : sum;
    for(i=0;i<61;i=i+1)byte(frame[i]);repeat(16)@(negedge clk);
    if(d!==ed || events!=before_events+((ep|er)!=0) || ((ep|er)!=0 && last_event!=={ep,er,ed}))
        $fatal(1,"parser to lane event D/P/R %h/%h expected %h/%h/%h",d,last_event,ed,ep,er);
end endtask
initial begin
    repeat(4)@(negedge clk);rst=0;wait(armed);
    report(8'h11,8'h21,3000,12000,2,0,9,0,9);
    report(8'h21,8'h11,3000,12000,2,0,0,0,9); // 记录换位并移动，仍绑定原轨
    report(8'h21,0,3000,0,1,0,0,1,8); // 压缩报告，编号2仍在原轨
    report(8'h21,8'h31,3000,6000,2,0,2,0,10); // 槽复用新增编号3
    report(8'h41,8'h31,9000,12000,2,0,4,8,6); // 同报告编号2消失、编号4按下
    report(8'h41,8'h31,100,100,2,1,0,0,6); // 校验错误不释放
    repeat(100)@(negedge clk);if(d!==6)$fatal(1,"stationary timeout released");
    report(8'h40,8'h30,9000,12000,2,0,0,6,0);
    $display("PASS real parser to lanes: reorder, compaction, slot reuse, atomic replacement, bad checksum, stationary hold");$finish;
end
initial begin #2000000;$fatal(1,"timeout");end
endmodule
