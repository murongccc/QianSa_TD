`timescale 1ns/1ps
module tb_touch_game_event_bridge;
parameter PHASE=7,HALF=19;
reg sc=0,dc=0;always #10 sc=~sc;initial begin #(PHASE);forever #(HALF) dc=~dc;end
reg rst=1,en=0,sv=0,ready=0;reg [3:0] sp=0,sr=0,sd=0;
reg signed [32:0] time_now=-96000;
time sent_at;
wire se,ev,ov,fault;wire signed [32:0] et;wire [3:0] p,r,d;
touch_game_event_bridge dut(sc,rst,dc,rst,en,se,sv,sp,sr,sd,time_now,ev,ready,et,p,r,d,ov,fault);
always @(negedge dc)if(!rst)time_now=time_now+1;
task send;input [3:0] ip,ir,id;begin
    @(negedge sc);sp=ip;sr=ir;sd=id;sv=1;sent_at=$time;@(negedge sc);sv=0;
end endtask
task receive;input [3:0] ip,ir,id;reg signed [32:0] stamp;begin
    wait(ev);@(negedge dc);stamp=et;
    repeat(20)begin @(negedge dc);if(!ev || p!==ip || r!==ir || et!==stamp)$fatal(1,"pending unstable");end
    ready=1;@(posedge dc);@(negedge dc);ready=0;
    if(d!==id)$fatal(1,"committed down");
end endtask
initial begin
    repeat(5)@(negedge sc);rst=0;en=1;wait(se);repeat(8)@(negedge dc);
    send(1,0,1);wait(ev);
    if(et!==time_now)$fatal(1,"timestamp was not first complete receive");
    $display("PASS empty bridge latency phase=%0d half=%0d: %0d ns, signed receive time %0d",PHASE,HALF,$time-sent_at,et);
    receive(1,0,1);
    send(0,1,0);wait(ev);repeat(10)begin @(negedge dc);if(d!==1)$fatal(1,"release bypassed pending event");end
    receive(0,1,0);
    // 快速按下/释放全入队，远短于一视频帧，顺序不能合并。
    send(2,0,2);send(0,2,0);receive(2,0,2);receive(0,2,0);
    send(4,0,4);wait(ev);send(0,4,0);repeat(12)@(negedge dc);
    send(8,0,8);send(0,8,0);send(1,0,1);repeat(12)@(negedge dc);
    if(!ov || !fault || se)$fatal(1,"queue full not fail closed");
    en=0;repeat(12)@(negedge dc);if(ev || d || ov)$fatal(1,"pause flush");
    en=1;wait(se);repeat(12)@(negedge dc);if(ev)$fatal(1,"stale event resumed");
    send(8,0,8);receive(8,0,8);
    // 只有一个视频周期的停用，也必须等源域清空确认才重新允许请求。
    send(1,8,1);wait(ev);@(negedge dc);en=0;@(negedge dc);en=1;
    repeat(30)@(negedge dc);if(ev || d)$fatal(1,"short pause leaked event");
    send(2,0,2);receive(2,0,2);
    rst=1;repeat(5)@(negedge dc);rst=0;repeat(12)@(negedge dc);
    if(ev || d || ov)$fatal(1,"reset stale");
    $display("PASS CDC phase=%0d half=%0d, stable time/masks, release ordering, fast tap, overflow, short pause/reset",PHASE,HALF);$finish;
end
initial begin #1000000;$fatal(1,"timeout");end
endmodule
